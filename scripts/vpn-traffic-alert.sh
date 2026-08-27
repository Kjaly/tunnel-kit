#!/bin/bash
# Контроль месячного ИСХОДЯЩЕГО трафика — это метрика, по которой считается лимит хостера
# (у DigitalOcean включённый egress: 1000 ГиБ на тарифе $6, овередж $0.01/ГиБ, пул на весь аккаунт).
#
#   vpn-traffic-alert.sh            тихая проверка: шлёт в Telegram только при пересечении порога
#   vpn-traffic-alert.sh --report   печатает отчёт и шлёт его в Telegram принудительно
#   vpn-traffic-alert.sh --dry      только печатает, ничего не шлёт
#   vpn-traffic-alert.sh --digest   недельная сводка (расход/неделя, месяц, топ, инциденты);
#                                   шлётся всегда, не зависит от порогов; ставится отдельным
#                                   таймером (см. install-traffic-monitor.sh)
#   vpn-traffic-alert.sh --monthly  итоги ПРОШЕДШЕГО календарного месяца (израсходовано, топ);
#                                   ставится на 1-е число, тоже всегда шлётся
#
# Месяц = календарный, по UTC (совпадает с биллингом хостера и с MonthRotate=1 у vnStat).
# Требует: vnstat (демон), jq. Данные по пользователям — от vpn-usage-collect.sh.
# --digest дополнительно читает /var/log/vpn-health.log (пишет vpn-healthcheck.sh).
set -uo pipefail

# ── настрой под себя (либо переопредели в vpn-alert.conf — он читается ниже) ──
SERVER_LABEL="MY-VPN"          # понятное имя сервера для алертов (напр. DO-AMS)
SERVER_IP="YOUR_SERVER_IP"     # публичный IP сервера
IFACE=eth0                     # публичный интерфейс
QUOTA_GIB=1000                 # включённый исходящий трафик тарифа, ГиБ/мес
WARN1=80; WARN2=95             # пороги предупреждений, %
# ─────────────────────────────────────────────────────────────────────────────

ALERT_CONF=/root/vpn-alert.conf
STATE=/var/lib/vpn-usage/alert.state
USAGE_DIR=/var/lib/vpn-usage

# Поправка на трафик, израсходованный ДО того как vnStat начал считать.
# Применяется только к указанному месяцу и отключается сама при его смене.
TRAFFIC_OFFSET_MONTH=""
TRAFFIC_OFFSET_GIB=0

# shellcheck disable=SC1090
[ -f "$ALERT_CONF" ] && . "$ALERT_CONF"

MODE="${1:-check}"
MONTH=$(date -u +%Y-%m)

# ── израсходовано за текущий календарный месяц ──
TX=$(vnstat --json m -i "$IFACE" 2>/dev/null \
     | jq -r --arg i "$IFACE" --arg y "$(date -u +%Y)" --arg m "$(date -u +%-m)" \
         '[ .interfaces[] | select(.name == $i) | .traffic.month[]?
            | select((.date.year|tostring) == $y and (.date.month|tostring) == $m) | .tx ] | first // 0' \
       2>/dev/null)
case "$TX" in ''|null|*[!0-9]*) TX=0;; esac

OFFSET=0
[ "$TRAFFIC_OFFSET_MONTH" = "$MONTH" ] && OFFSET="$TRAFFIC_OFFSET_GIB"

read -r USED PCT AVG PROJ LEFT_D <<<"$(awk -v tx="$TX" -v off="$OFFSET" -v q="$QUOTA_GIB" \
  -v dom="$(date -u +%-d)" -v hr="$(date -u +%-H)" \
  -v dim="$(date -u -d "$(date -u +%Y-%m-01) +1 month -1 day" +%-d)" '
BEGIN{
  used = tx/1073741824 + off;
  elapsed = (dom-1) + hr/24; if (elapsed < 0.25) elapsed = 0.25;
  printf "%.1f %.1f %.2f %.0f %.1f", used, used/q*100, used/elapsed, used/elapsed*dim, dim-elapsed;
}')"

# ── топ потребителей за месяц ──
TOP=$(jq -r 'to_entries
  | map({e:.key, gb: (((.value.uplink // 0) + (.value.downlink // 0)) / 1073741824)})
  | sort_by(-.gb) | .[:5][]
  | "  • \(.e): \(.gb * 100 | round / 100) ГиБ"' "$USAGE_DIR/$MONTH.json" 2>/dev/null)
[ -z "$TOP" ] && TOP="  • (данных пока нет)"

LEVEL=$(awk -v p="$PCT" -v w1="$WARN1" -v w2="$WARN2" \
  'BEGIN{ if (p>=100) print 3; else if (p>=w2) print 2; else if (p>=w1) print 1; else print 0 }')

case "$LEVEL" in
  3) ICON="🔴"; HEAD="ЛИМИТ ИСЧЕРПАН";;
  2) ICON="🟠"; HEAD="Трафик ${PCT}% квоты";;
  1) ICON="🟡"; HEAD="Трафик ${PCT}% квоты";;
  *) ICON="🟢"; HEAD="Трафик ${PCT}% квоты";;
esac

MSG="${ICON} <b>${HEAD} · ${SERVER_LABEL}</b>
🖥 <code>${SERVER_IP}</code> · ${MONTH}
<blockquote>Израсходовано: <b>${USED}</b> / ${QUOTA_GIB} ГиБ (${PCT}%)
Темп: ${AVG} ГиБ/сут · прогноз к концу месяца: <b>${PROJ}</b> ГиБ
До конца месяца: ${LEFT_D} дн.</blockquote>
<b>По пользователям:</b>
${TOP}
🕐 $(date "+%d.%m %H:%M")"

send() {
  [ -n "${BOT_TOKEN:-}" ] && [ -n "${CHAT_ID:-}" ] || return 0
  curl -s --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" -d parse_mode=HTML --data-urlencode "text=$1" >/dev/null 2>&1
}

case "$MODE" in
  --dry)    printf '%s\n' "$MSG" | sed 's/<[^>]*>//g';;
  --report) printf '%s\n' "$MSG" | sed 's/<[^>]*>//g'; send "$MSG";;
  --digest)
    HEALTH_LOG=/var/log/vpn-health.log
    CUTOFF=$(date -u -d '7 days ago' +%Y-%m-%d)

    # ── расход за прошедшую неделю (7 полных суток до сегодня, UTC) ──
    WEEK_DAYS=$(printf '"%s",' $(for i in 1 2 3 4 5 6 7; do date -u -d "-$i day" +%Y-%m-%d; done) | sed 's/,$//')
    WEEK_TX=$(vnstat --json d -i "$IFACE" 2>/dev/null \
      | jq -r --arg i "$IFACE" --argjson days "[$WEEK_DAYS]" \
          '[ .interfaces[] | select(.name == $i) | .traffic.day[]?
             | ("\(.date.year)-" + (.date.month|tostring|if length==1 then "0"+. else . end)
                + "-" + (.date.day|tostring|if length==1 then "0"+. else . end)) as $d
             | select($days | index($d)) | .tx ] | add // 0' 2>/dev/null)
    case "$WEEK_TX" in ''|null|*[!0-9]*) WEEK_TX=0;; esac
    read -r WEEK_GIB WEEK_AVG <<<"$(awk -v tx="$WEEK_TX" 'BEGIN{ g=tx/1073741824; printf "%.1f %.1f", g, g/7 }')"

    # ── инциденты за неделю: считаем переходы OK → WARN/CRIT, не каждую строку лога ──
    INCIDENTS=0
    [ -f "$HEALTH_LOG" ] && INCIDENTS=$(awk -v cutoff="$CUTOFF" '
      $1 >= cutoff {
        sev = $3; if (prev == "") prev = "OK"
        if (prev == "OK" && sev != "OK") n++
        prev = sev
      }
      END { print n+0 }' "$HEALTH_LOG" 2>/dev/null)
    case "$INCIDENTS" in ''|*[!0-9]*) INCIDENTS=0;; esac
    if [ "$INCIDENTS" -eq 0 ]; then INC_TXT="без инцидентов ✅"; else INC_TXT="${INCIDENTS} шт. (детали — /var/log/vpn-health.log)"; fi

    DIGEST_MSG="📅 <b>Недельный дайджест · ${SERVER_LABEL}</b>
🖥 <code>${SERVER_IP}</code> · неделя до $(date -u +%d.%m.%Y)
<blockquote>За неделю: <b>${WEEK_GIB}</b> ГиБ · темп ${WEEK_AVG} ГиБ/сут
За месяц (${MONTH}): <b>${USED}</b> / ${QUOTA_GIB} ГиБ (${PCT}%) · прогноз к концу месяца: ${PROJ} ГиБ
Инциденты за неделю: ${INC_TXT}</blockquote>
<b>Топ за месяц:</b>
${TOP}
🕐 $(date "+%d.%m %H:%M")"

    printf '%s\n' "$DIGEST_MSG" | sed 's/<[^>]*>//g'
    send "$DIGEST_MSG"
    ;;
  --monthly)
    # Запускается 1-го числа: $MONTH к этому моменту УЖЕ новый, поэтому считаем отдельно
    # для месяца, который только что закончился.
    PM_MONTH=$(date -u -d 'last month' +%Y-%m)
    PM_Y=$(date -u -d 'last month' +%Y)
    PM_M=$(date -u -d 'last month' +%-m)

    PM_TX=$(vnstat --json m -i "$IFACE" 2>/dev/null \
      | jq -r --arg i "$IFACE" --arg y "$PM_Y" --arg m "$PM_M" \
          '[ .interfaces[] | select(.name == $i) | .traffic.month[]?
             | select((.date.year|tostring) == $y and (.date.month|tostring) == $m) | .tx ] | first // 0' \
        2>/dev/null)
    case "$PM_TX" in ''|null|*[!0-9]*) PM_TX=0;; esac

    PM_OFFSET=0
    [ "$TRAFFIC_OFFSET_MONTH" = "$PM_MONTH" ] && PM_OFFSET="$TRAFFIC_OFFSET_GIB"

    read -r PM_USED PM_PCT <<<"$(awk -v tx="$PM_TX" -v off="$PM_OFFSET" -v q="$QUOTA_GIB" \
      'BEGIN{ used = tx/1073741824 + off; printf "%.1f %.1f", used, used/q*100 }')"

    PM_TOP=$(jq -r 'to_entries
      | map({e:.key, gb: (((.value.uplink // 0) + (.value.downlink // 0)) / 1073741824)})
      | sort_by(-.gb) | .[:5][]
      | "  • \(.e): \(.gb * 100 | round / 100) ГиБ"' "$USAGE_DIR/$PM_MONTH.json" 2>/dev/null)
    [ -z "$PM_TOP" ] && PM_TOP="  • (данных нет)"

    MONTHLY_MSG="🗓 <b>Итоги месяца ${PM_MONTH} · ${SERVER_LABEL}</b>
🖥 <code>${SERVER_IP}</code>
<blockquote>Израсходовано: <b>${PM_USED}</b> / ${QUOTA_GIB} ГиБ (${PM_PCT}%)</blockquote>
<b>Топ пользователей:</b>
${PM_TOP}
🕐 $(date "+%d.%m %H:%M")"

    printf '%s\n' "$MONTHLY_MSG" | sed 's/<[^>]*>//g'
    send "$MONTHLY_MSG"
    ;;
  *)
    # Каждый уровень шлётся один раз за месяц; смена месяца сбрасывает состояние.
    PREV_MONTH=""; PREV_LEVEL=0
    [ -f "$STATE" ] && IFS=: read -r PREV_MONTH PREV_LEVEL < "$STATE"
    [ "$PREV_MONTH" != "$MONTH" ] && PREV_LEVEL=0
    printf '%s:%s\n' "$MONTH" "$LEVEL" > "$STATE"
    [ "$LEVEL" -gt "${PREV_LEVEL:-0}" ] && send "$MSG"
    ;;
esac
exit 0
