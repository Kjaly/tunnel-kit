#!/bin/bash
# Сливает (-reset) per-user счётчики xray и аккумулирует их помесячно.
#   → /var/lib/vpn-usage/YYYY-MM.json   формата {"email": {"uplink": N, "downlink": N}}
#
# Зачем: счётчики xray живут в памяти и обнуляются при рестарте сервиса.
# Коллектор забирает дельту каждые N минут, поэтому рестарт xray не теряет историю.
# Ставится таймером на 10 минут (см. install-traffic-monitor.sh).
#
# Требует включённого Stats API — см. enable-xray-stats.sh
#
# Дополнительно: сверяет расход каждого email с личной квотой из
# /var/lib/vpn-usage/users.json (пишет vpnctl.sh set-quota) и шлёт в Telegram
# алерт с кнопкой "Отключить" (callback_data=askdel:<email>, обрабатывает vpnbot.py)
# — один раз в месяц на пользователя, состояние в quota-alert.state.
set -uo pipefail

API=127.0.0.1:10085
DIR=/var/lib/vpn-usage
MONTH=$(date -u +%Y-%m)
FILE="$DIR/$MONTH.json"
USERS_FILE="$DIR/users.json"
QALERT_STATE="$DIR/quota-alert.state"
ALERT_CONF=/root/vpn-alert.conf

mkdir -p "$DIR"
[ -s "$FILE" ] || echo '{}' > "$FILE"
[ -s "$USERS_FILE" ] || echo '{}' > "$USERS_FILE"
[ -s "$QALERT_STATE" ] || echo '{}' > "$QALERT_STATE"

RAW=$(xray api statsquery --server="$API" -pattern "user>>>" -reset 2>/dev/null) || exit 0

DELTA=$(printf '%s' "$RAW" | jq -c '[ (.stat // [])[]
    | select(.name | startswith("user>>>"))
    | {email: (.name | split(">>>")[1]), dir: (.name | split(">>>")[3]), v: (.value // 0)} ]') || exit 0
[ -n "$DELTA" ] && jq --argjson d "$DELTA" '
  reduce $d[] as $x (.; .[$x.email] = ((.[$x.email] // {}) | .[$x.dir] = ((.[$x.dir] // 0) + $x.v)))
' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"

# ── личные квоты: кто превысил и ещё не получал алерт в этом месяце ──
# shellcheck disable=SC1090
[ -f "$ALERT_CONF" ] && . "$ALERT_CONF"
send() {
  [ -n "${BOT_TOKEN:-}" ] && [ -n "${CHAT_ID:-}" ] || return 0
  curl -s --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" -d parse_mode=HTML \
    --data-urlencode "text=$1" --data-urlencode "reply_markup=$2" >/dev/null 2>&1
}

QCHECK=$(jq -n --slurpfile usage "$FILE" --slurpfile users "$USERS_FILE" --slurpfile st "$QALERT_STATE" \
  --arg month "$MONTH" '
  ($usage[0] // {}) as $u | ($users[0] // {}) as $qs | ($st[0] // {}) as $s |
  [ $qs | to_entries[] | select(.value.quota_gib != null) |
    ($u[.key] // {}) as $uu |
    ((($uu.uplink // 0) + ($uu.downlink // 0)) / 1073741824) as $gib |
    select($gib > .value.quota_gib) |
    select(($s[.key] // "") != $month) |
    {email: .key, gib: ($gib*100|round/100), quota: .value.quota_gib}
  ]' 2>/dev/null) || QCHECK="[]"
[ -z "$QCHECK" ] && QCHECK="[]"

if [ "$QCHECK" != "[]" ]; then
  echo "$QCHECK" | jq -c '.[]' | while IFS= read -r row; do
    E=$(printf '%s' "$row" | jq -r '.email')
    [[ "$E" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ ]] || continue
    GIB=$(printf '%s' "$row" | jq -r '.gib')
    Q=$(printf '%s' "$row" | jq -r '.quota')
    KB='{"inline_keyboard":[[{"text":"Отключить","callback_data":"askdel:'"$E"'"}]]}'
    MSG="🟠 <b>Превышена личная квота</b>
Пользователь: <code>${E}</code>
Израсходовано: <b>${GIB}</b> / ${Q} ГиБ (${MONTH})"
    send "$MSG" "$KB"
  done

  jq --argjson rows "$QCHECK" --arg month "$MONTH" '
    reduce $rows[] as $r (.; .[$r.email] = $month)
  ' "$QALERT_STATE" > "$QALERT_STATE.tmp" && mv "$QALERT_STATE.tmp" "$QALERT_STATE"
fi
