#!/bin/bash
# Включает в xray Stats API + per-client email-теги, чтобы видеть трафик по каждому пользователю.
#   enable-xray-stats.sh [email-первого-клиента]      (по умолчанию user@main)
#
# Что делает:
#   • stats + api(StatsService) + policy со счётчиками по пользователям
#   • inbound dokodemo-door на 127.0.0.1:10085 (наружу НЕ торчит) с тегом "api"
#   • тег "vless-in" боевому inbound + email клиентам, у которых его ещё нет
#   • правило роутинга api -> api первым в списке
#
# Идемпотентен: повторный запуск ничего не ломает и не дублирует.
# Безопасность: бэкап -> валидация `xray run -test` -> рестарт -> проверка портов -> автооткат.
set -euo pipefail

CFG=/usr/local/etc/xray/config.json
EMAIL="${1:-user@main}"
STAMP=$(date +%Y%m%d-%H%M%S)
BAK="${CFG}.bak.${STAMP}"
TMP=$(mktemp /tmp/xray-cfg.XXXXXX.json)

command -v jq >/dev/null || { echo "❌ нужен jq: apt-get install -y jq"; exit 1; }
[ -f "$CFG" ] || { echo "❌ не найден $CFG"; exit 1; }

cp -a "$CFG" "$BAK"
echo "бэкап: $BAK"

jq --arg email "$EMAIL" '
  .stats = {}
| .api = {"tag":"api","services":["StatsService"]}
| .policy = {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
    "system": {
      "statsInboundUplink": true,  "statsInboundDownlink": true,
      "statsOutboundUplink": true, "statsOutboundDownlink": true
    }
  }
| .inbounds |= (map(
    if .protocol == "vless" then
        (.tag = (.tag // "vless-in"))
      | (.settings.clients |= map(if (.email // "") == "" then .email = $email else . end))
    else . end))
| .inbounds |= (map(select(.tag != "api")) + [{
    "listen": "127.0.0.1",
    "port": 10085,
    "protocol": "dokodemo-door",
    "settings": {"address": "127.0.0.1"},
    "tag": "api"
  }])
| .routing.rules = ([{"type":"field","inboundTag":["api"],"outboundTag":"api"}]
                    + (.routing.rules | map(select((.inboundTag // []) | index("api") | not))))
' "$CFG" > "$TMP"

echo "--- изменения (ключи вырезаны) ---"
mask() { sed -E 's/("(id|privateKey|password)"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"<HIDDEN>"/g' "$1"; }
diff <(mask "$CFG") <(mask "$TMP") || true

echo "--- валидация ---"
if ! xray run -test -config "$TMP"; then
  echo "❌ конфиг не прошёл валидацию — ничего не меняю"
  rm -f "$TMP"; exit 1
fi

install -m 644 -o root -g root "$TMP" "$CFG"
rm -f "$TMP"

systemctl restart xray
sleep 3

if systemctl is-active --quiet xray && ss -tln | grep -q ':443 ' && ss -tln | grep -q '127.0.0.1:10085'; then
  echo "✅ xray active, :443 и 127.0.0.1:10085 слушают"
else
  echo "❌ проблема после рестарта — откат на $BAK"
  cp -a "$BAK" "$CFG"; systemctl restart xray; sleep 2
  systemctl is-active xray || true
  exit 1
fi

echo "--- проверка Stats API ---"
xray api statsquery --server=127.0.0.1:10085 -pattern '' \
  || echo "(счётчики пустые сразу после рестарта — это нормально)"

cat <<'EOF'

Дальше:
  xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>"
  xray api stats --server=127.0.0.1:10085 -name "user>>>ИМЯ@УСТРОЙСТВО>>>traffic>>>downlink"

Счётчики xray обнуляются при рестарте сервиса — для помесячного учёта
поставь коллектор: install-traffic-monitor.sh
EOF
