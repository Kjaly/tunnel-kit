#!/usr/bin/env python3
"""
wg-conf-to-routes.py — из WireGuard .conf делает маршруты для роутера Keenetic/Netcraze.

Зачем это нужно
---------------
В веб-интерфейсе Keenetic поле «Разрешённые подсети» (AllowedIPs) — это ФИЛЬТР
(crypto routing), а не таблица маршрутизации. Документация вендора прямым текстом:
чтобы трафик пошёл в удалённые сети, маршруты надо добавить ОТДЕЛЬНО.

То есть импорта .conf недостаточно: туннель поднимется, handshake пройдёт,
а трафик в него не пойдёт. Нужны статические маршруты — по одному на каждую
подсеть из AllowedIPs. Руками для 30+ адресов это невыносимо.

Что делает скрипт
-----------------
1. Разбирает .conf и достаёт AllowedIPs.
2. Ищет пересечения с домашней подсетью — самая частая тихая поломка
   (маршрут /32 на локальный адрес делает домашнее устройство недоступным,
   а выглядит это как «глючит Wi-Fi»).
3. Генерирует три формата:
   - bat   — файл для массового импорта в веб-интерфейсе (Маршрутизация →
             Статические маршруты → Загрузить), интерфейс выбирается при импорте;
   - cli   — команды `ip route` для консоли роутера;
   - xkeen — список для ip_exclude.lst, чтобы XKeen не утащил корпоративный
             трафик в прокси (XKeen перехватывает пакеты РАНЬШЕ таблицы
             маршрутизации, поэтому без исключений маршруты не спасут).

Примеры
-------
    ./wg-conf-to-routes.py work-wireguard.conf
    ./wg-conf-to-routes.py work-wireguard.conf --home-subnet 192.168.10.0/24
    ./wg-conf-to-routes.py work-wireguard.conf --format cli --interface Wireguard0
    ./wg-conf-to-routes.py work-wireguard.conf --format xkeen > ip_exclude.lst

Зависимостей нет, только стандартная библиотека.
"""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Подсети, которые не имеет смысла заворачивать в туннель по отдельным маршрутам:
# 0.0.0.0/0 означает «весь трафик» и настраивается галкой в интерфейсе, а не маршрутами.
FULL_TUNNEL = {ipaddress.ip_network("0.0.0.0/0"), ipaddress.ip_network("::/0")}

DEFAULT_HOME_SUBNET = "192.168.1.0/24"

Network = ipaddress.IPv4Network | ipaddress.IPv6Network


@dataclass
class WgConfig:
    """Разобранный .conf. Хранит только то, что нужно для маршрутов."""

    allowed_ips: list[Network] = field(default_factory=list)
    address: list[Network] = field(default_factory=list)
    dns: list[str] = field(default_factory=list)
    endpoint: str | None = None
    full_tunnel: bool = False


def parse_wg_conf(path: Path) -> WgConfig:
    """Разбирает WireGuard-конфиг. Секции не различаем — нам нужны только ключи."""
    cfg = WgConfig()

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("["):
            continue

        key, sep, value = line.partition("=")
        if not sep:
            continue
        key, value = key.strip().lower(), value.strip()

        if key == "allowedips":
            for chunk in _split_list(value):
                net = _parse_network(chunk)
                if net is None:
                    continue
                if net in FULL_TUNNEL:
                    cfg.full_tunnel = True
                    continue
                cfg.allowed_ips.append(net)
        elif key == "address":
            for chunk in _split_list(value):
                net = _parse_network(chunk)
                if net is not None:
                    cfg.address.append(net)
        elif key == "dns":
            cfg.dns.extend(_split_list(value))
        elif key == "endpoint":
            cfg.endpoint = value

    return cfg


def _split_list(value: str) -> list[str]:
    return [chunk.strip() for chunk in re.split(r"[,\s]+", value) if chunk.strip()]


def _parse_network(chunk: str) -> Network | None:
    """`1.2.3.4` → /32, `1.2.3.0/24` → как есть. Мусор молча пропускаем."""
    try:
        return ipaddress.ip_network(chunk, strict=False)
    except ValueError:
        print(f"warning: не разобрал адрес {chunk!r}, пропускаю", file=sys.stderr)
        return None


def find_collisions(networks: list[Network], home: Network) -> list[Network]:
    """Адреса из туннеля, попадающие в домашнюю подсеть."""
    return [net for net in networks if net.version == home.version and net.overlaps(home)]


def emit_bat(networks: list[Network], gateway: str) -> str:
    """
    Формат для массового импорта в веб-интерфейсе: синтаксис Windows `route add`.
    Интерфейс (WireGuard-подключение) выбирается в форме загрузки, не здесь.
    """
    lines = [
        "REM Импорт: Сетевые правила -> Маршрутизация -> Статические маршруты -> Загрузить",
        "REM Интерфейс (WireGuard-подключение) выбирается в форме загрузки.",
        f"REM Маршрутов: {len(networks)}",
        "",
    ]
    for net in networks:
        lines.append(f"route ADD {net.network_address} MASK {net.netmask} {gateway}")
    return "\n".join(lines)


def emit_cli(networks: list[Network], interface: str) -> str:
    """Команды для консоли роутера (SSH/Telnet). Без `system configuration save` изменения не переживут ребут."""
    lines = [
        "! Вставить в консоль роутера, затем обязательно сохранить.",
        f"! Интерфейс: {interface}. Уточни реальное имя командой `show interface`.",
        "",
    ]
    for net in networks:
        lines.append(f"ip route {net.network_address} {net.netmask} {interface} auto")
    lines += ["", "system configuration save"]
    return "\n".join(lines)


def emit_xkeen(networks: list[Network]) -> str:
    """
    Список для ip_exclude.lst.

    XKeen перехватывает трафик в PREROUTING, то есть РАНЬШЕ, чем работает таблица
    маршрутизации. Без этого списка корпоративные адреса уедут в прокси мимо туннеля,
    и маршруты выше ничего не спасут.
    """
    lines = [
        "# Корпоративные адреса — мимо прокси XKeen, они идут в WireGuard-туннель.",
        "# Положить в ip_exclude.lst и перезапустить: xkeen -restart",
        "",
    ]
    lines.extend(str(net) for net in networks)
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Из WireGuard .conf — маршруты для Keenetic/Netcraze.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("conf", type=Path, help="путь к .conf")
    parser.add_argument(
        "--format",
        choices=("bat", "cli", "xkeen", "all"),
        default="all",
        help="что вывести (по умолчанию всё)",
    )
    parser.add_argument(
        "--home-subnet",
        default=DEFAULT_HOME_SUBNET,
        help=f"домашняя подсеть для проверки пересечений (по умолчанию {DEFAULT_HOME_SUBNET})",
    )
    parser.add_argument(
        "--interface",
        default="Wireguard0",
        help="имя WireGuard-интерфейса на роутере для формата cli",
    )
    parser.add_argument(
        "--gateway",
        default="0.0.0.0",
        help="шлюз в bat-файле; при импорте интерфейс всё равно выбирается в форме",
    )
    args = parser.parse_args()

    if not args.conf.is_file():
        print(f"error: не нашёл файл {args.conf}", file=sys.stderr)
        return 1

    try:
        home = ipaddress.ip_network(args.home_subnet, strict=False)
    except ValueError:
        print(f"error: не разобрал домашнюю подсеть {args.home_subnet!r}", file=sys.stderr)
        return 1

    cfg = parse_wg_conf(args.conf)

    if cfg.full_tunnel:
        print(
            "warning: в AllowedIPs есть 0.0.0.0/0 — это full tunnel.\n"
            "         Он включается галкой в настройках подключения, а не маршрутами.",
            file=sys.stderr,
        )

    if not cfg.allowed_ips:
        print("error: в AllowedIPs нет ни одной подсети для маршрутов", file=sys.stderr)
        return 1

    # Дедуп с сохранением порядка — в реальных конфигах дубли встречаются.
    networks: list[Network] = list(dict.fromkeys(cfg.allowed_ips))

    collisions = find_collisions(networks, home)

    print(f"# Источник:        {args.conf}")
    print(f"# Подсетей:        {len(networks)}")
    print(f"# Домашняя сеть:   {home}")
    if cfg.endpoint:
        print(f"# Endpoint:        {cfg.endpoint}")
    if cfg.dns:
        print(f"# DNS из конфига:  {', '.join(cfg.dns)}")
        print("#   -> «Маршруты DNS» на KeeneticOS 5.0/5.1 несовместимы с политиками XKeen.")
        print("#      Корпоративный домен вешать условным upstream'ом в AdGuard Home.")
    print()

    if collisions:
        print("#" + "=" * 70)
        print("# ВНИМАНИЕ: пересечение с домашней подсетью")
        for net in collisions:
            print(f"#   {net}")
        print("#")
        print("# Маршрут в туннель перебьёт локальный адрес: домашнее устройство станет")
        print("# недоступно, а выглядеть это будет как «глючит сеть», а не как ошибка маршрута.")
        print("# Лечится сменой домашней подсети (например, 192.168.10.0/24)")
        print("# либо исключением этих адресов из списка.")
        print("#" + "=" * 70)
        print()

    blocks: list[tuple[str, str]] = []
    if args.format in ("bat", "all"):
        blocks.append(("bat — массовый импорт в веб-интерфейсе", emit_bat(networks, args.gateway)))
    if args.format in ("cli", "all"):
        blocks.append(("cli — команды для консоли роутера", emit_cli(networks, args.interface)))
    if args.format in ("xkeen", "all"):
        blocks.append(("xkeen — ip_exclude.lst", emit_xkeen(networks)))

    for title, body in blocks:
        if args.format == "all":
            print(f"\n{'=' * 72}\n# {title}\n{'=' * 72}\n")
        print(body)

    return 2 if collisions else 0


if __name__ == "__main__":
    sys.exit(main())
