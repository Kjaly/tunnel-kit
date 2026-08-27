#!/usr/bin/env python3
"""
shadowrocket-to-xray.py — переносит правила Shadowrocket в routing для Xray/XKeen.

Зачем это нужно
---------------
Когда VPN переезжает с телефона на роутер, выстраданный список «что идёт напрямую»
надо перенести в Xray. Руками это 150+ строк с переименованием синтаксиса.

Плюс одна тихая ловушка, на которой спотыкаются все гайды по XKeen:

    geoip:ru  НЕ РАБОТАЕТ

Xray читает префикс `geoip:` строго из файла `geoip.dat`, а XKeen раскладывает
базы под другими именами (`geoip_v2fly.dat` и подобные). Конфиг при этом валиден,
роутер работает, ошибок в логе нет — просто правило молча не срабатывает, и весь
российский трафик идёт через VPS. Узнаёшь об этом, когда банк попросит подтвердить
вход из другой страны. Правильная запись — `ext:geoip_v2fly.dat:ru`.

Соответствие синтаксиса
-----------------------
    DOMAIN-SUFFIX,example.com   ->  domain:example.com
    DOMAIN,example.com          ->  full:example.com
    DOMAIN-KEYWORD,example      ->  keyword:example
    IP-CIDR,10.0.0.0/8          ->  ip: 10.0.0.0/8
    GEOIP,RU                    ->  ip: ext:geoip_v2fly.dat:ru

Примеры
-------
    ./shadowrocket-to-xray.py ru-direct.list
    ./shadowrocket-to-xray.py ru-direct.list -o 05_routing.json
    ./shadowrocket-to-xray.py ru-direct.list --geoip-file geoip_antifilter.dat
    ./shadowrocket-to-xray.py ru-direct.list --strict-json   # без комментариев

Зависимостей нет, только стандартная библиотека.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

DEFAULT_GEOIP_FILE = "geoip_v2fly.dat"

# Тип правила Shadowrocket -> префикс в Xray. None означает, что это IP-правило.
DOMAIN_PREFIX = {
    "DOMAIN-SUFFIX": "domain:",
    "DOMAIN": "full:",
    "DOMAIN-KEYWORD": "keyword:",
    "HOST-SUFFIX": "domain:",
    "HOST": "full:",
    "HOST-KEYWORD": "keyword:",
}
IP_TYPES = {"IP-CIDR", "IP-CIDR6", "IP6-CIDR", "GEOIP"}

# Правила, которые на роутере не имеют смысла или требуют ручного решения.
UNSUPPORTED = {
    "USER-AGENT": "Xray не разбирает User-Agent",
    "URL-REGEX": "Xray не работает на уровне URL",
    "PROCESS-NAME": "на роутере нет понятия процесса",
    "DEST-PORT": "переносится вручную правилом с полем port",
    "SRC-IP": "переносится вручную правилом с полем source",
    "RULE-SET": "вложенные списки надо разворачивать заранее",
    "FINAL": "хвостовое правило задаётся отдельно",
}


def parse_rules(path: Path, geoip_file: str) -> tuple[list[str], list[str], list[str]]:
    """Возвращает (домены, ip, предупреждения)."""
    domains: OrderedDict[str, None] = OrderedDict()
    ips: OrderedDict[str, None] = OrderedDict()
    warnings: list[str] = []

    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(("#", ";", "//")):
            continue

        parts = [p.strip() for p in line.split(",")]
        kind = parts[0].upper()

        if kind in UNSUPPORTED:
            warnings.append(f"строка {lineno}: {kind} пропущен — {UNSUPPORTED[kind]}")
            continue

        if len(parts) < 2:
            warnings.append(f"строка {lineno}: не разобрал {line!r}")
            continue

        value = parts[1]

        if kind in DOMAIN_PREFIX:
            domains[f"{DOMAIN_PREFIX[kind]}{value.lower()}"] = None
        elif kind == "GEOIP":
            # Ровно то место, где ломаются все гайды.
            ips[f"ext:{geoip_file}:{value.lower()}"] = None
        elif kind in IP_TYPES:
            if _valid_cidr(value):
                ips[value] = None
            else:
                warnings.append(f"строка {lineno}: {value!r} не похоже на подсеть")
        else:
            warnings.append(f"строка {lineno}: неизвестный тип {kind}")

    return list(domains), list(ips), warnings


def _valid_cidr(value: str) -> bool:
    try:
        ipaddress.ip_network(value, strict=False)
        return True
    except ValueError:
        return False


def build_routing(domains: list[str], ips: list[str], outbound: str, fallback: str) -> dict:
    """
    Собирает секцию routing. Порядок правил важен: Xray применяет первое совпавшее.

    Приватные адреса идут первыми — иначе локальная сеть уедет в прокси. Это же
    правило, кстати, в серверных конфигах часто блокирует geoip:private целиком,
    и тогда ломается резолв через 127.0.0.53.
    """
    rules: list[dict] = [
        {
            "_comment": "Локальная сеть и приватные адреса — всегда напрямую.",
            "ip": ["geoip:private"],
            "outboundTag": outbound,
        }
    ]

    if domains:
        rules.append(
            {
                "_comment": f"Домены напрямую, перенесено из списка ({len(domains)} шт.).",
                "domain": domains,
                "outboundTag": outbound,
            }
        )

    if ips:
        rules.append(
            {
                "_comment": f"IP и geo-базы напрямую ({len(ips)} шт.).",
                "ip": ips,
                "outboundTag": outbound,
            }
        )

    rules.append(
        {
            "_comment": "Всё остальное — в туннель.",
            "network": "tcp,udp",
            "outboundTag": fallback,
        }
    )

    return {"routing": {"domainStrategy": "IPIfNonMatch", "rules": rules}}


def render(routing: dict, strict: bool) -> str:
    """
    Xray принимает JSON с комментариями `//`, и XKeen сам кладёт такие конфиги
    в поставке. Но если конфиг проходит через строгий парсер — нужен --strict-json.
    """
    if strict:
        cleaned = json.loads(json.dumps(routing))
        for rule in cleaned["routing"]["rules"]:
            rule.pop("_comment", None)
        return json.dumps(cleaned, ensure_ascii=False, indent=2)

    lines = ["{", '  "routing": {', '    "domainStrategy": "IPIfNonMatch",', '    "rules": [']
    rules = routing["routing"]["rules"]
    for index, rule in enumerate(rules):
        body = {k: v for k, v in rule.items() if k != "_comment"}
        chunk = json.dumps(body, ensure_ascii=False, indent=2)
        chunk = "\n".join("      " + ln for ln in chunk.splitlines())
        lines.append(f"      // {rule['_comment']}")
        lines.append(chunk + ("," if index < len(rules) - 1 else ""))
    lines += ["    ]", "  }", "}"]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Правила Shadowrocket -> routing для Xray/XKeen.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("rules", type=Path, help="список правил (напр. ru-direct.list)")
    parser.add_argument("-o", "--output", type=Path, help="куда писать (по умолчанию stdout)")
    parser.add_argument(
        "--geoip-file",
        default=DEFAULT_GEOIP_FILE,
        help=(
            f"имя geo-базы в /opt/etc/xray/dat (по умолчанию {DEFAULT_GEOIP_FILE}). "
            "Проверь реальное имя: ls /opt/etc/xray/dat"
        ),
    )
    parser.add_argument("--outbound", default="direct", help="тег для прямых правил")
    parser.add_argument("--fallback", default="proxy", help="тег для всего остального")
    parser.add_argument("--strict-json", action="store_true", help="без комментариев")
    args = parser.parse_args()

    if not args.rules.is_file():
        print(f"error: не нашёл файл {args.rules}", file=sys.stderr)
        return 1

    domains, ips, warnings = parse_rules(args.rules, args.geoip_file)

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)

    if not domains and not ips:
        print("error: не нашёл ни одного пригодного правила", file=sys.stderr)
        return 1

    routing = build_routing(domains, ips, args.outbound, args.fallback)
    text = render(routing, args.strict_json)

    if args.output:
        args.output.write_text(text + "\n", encoding="utf-8")
        print(f"записал {args.output}", file=sys.stderr)
    else:
        print(text)

    print(
        f"\nитого: доменов {len(domains)}, ip-правил {len(ips)}, пропущено {len(warnings)}",
        file=sys.stderr,
    )
    if not any(ip.startswith("ext:") for ip in ips):
        print(
            "\nподсказка: в списке нет geo-правил. Если хочешь пускать весь российский\n"
            f"трафик напрямую, добавь строку `GEOIP,RU` — она развернётся в\n"
            f"`ext:{args.geoip_file}:ru`, а НЕ в нерабочее `geoip:ru`.",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
