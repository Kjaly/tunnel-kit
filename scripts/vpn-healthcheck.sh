#!/bin/bash
# Health-check + авто-восстановление VPN. Запускается systemd-таймером каждые 5 мин.
# Проверяет: xray, (опц.) caddy-подписку, исходящий интернет, регион OpenAI.
# При проблеме — авто-рестарт сервиса + (опц.) Telegram-алерт при смене статуса.
#
# Установка:
#   1) впиши SERVER_IP ниже
#   2) sudo cp scripts/vpn-healthcheck.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/vpn-healthcheck.sh
#   3) заведи systemd service+timer (см. optional-enhancements.md)
set -u

# ── настрой под себя ────────────────────────────────────────────────
SERVER_LABEL="MY-VPN"               # понятное имя сервера для алертов (напр. DO-AMS)
SERVER_IP="YOUR_SERVER_IP"          # публичный IP сервера
SUB_PORT="8443"                     # порт подписки (если поднимал subscription-сервер; иначе не важно)
# ────────────────────────────────────────────────────────────────────

LOG=/var/log/vpn-health.log
STATE=/run/vpn-health.state
ALERT_CONF=/root/vpn-alert.conf     # опционально: BOT_TOKEN=... / CHAT_ID=...
SUB_SECRET=$(cat /root/sub-secret.txt 2>/dev/null)   # если есть subscription-сервер
SSLIP="${SERVER_IP}.sslip.io"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(ts) $1" >> "$LOG"; }
problems=()

# 1. xray активен и слушает 443
if ! systemctl is-active --quiet xray || ! ss -tln | grep -q ':443 '; then
  systemctl restart xray; sleep 2
  if systemctl is-active --quiet xray && ss -tln | grep -q ':443 '; then
    problems+=("xray был не в порядке -> перезапущен (ОК)")
  else
    problems+=("xray НЕ поднимается после рестарта")
  fi
fi

# 2. (опц.) caddy + подписка отдаётся
if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
  if ! systemctl is-active --quiet caddy; then
    systemctl restart caddy; sleep 2
    problems+=("caddy был down -> перезапущен")
  fi
  if [ -n "$SUB_SECRET" ]; then
    code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 --resolve "$SSLIP:$SUB_PORT:127.0.0.1" "https://$SSLIP:$SUB_PORT/$SUB_SECRET/nodes")
    [ "$code" != "200" ] && problems+=("подписка не отдаётся (код $code)")
  fi
fi

# 3. исходящий интернет + регион OpenAI (форс IPv4)
exit_ip=$(curl -4 -s --max-time 10 https://ifconfig.me)
loc=""
if [ -z "$exit_ip" ]; then
  problems+=("нет исходящего интернета")
else
  loc=$(curl -4 -s --max-time 10 https://chatgpt.com/cdn-cgi/trace | grep "^loc=" | cut -d= -f2 | tr -d "\r")
  [ "$loc" = "RU" ] && problems+=("!!! OpenAI видит регион RU (IP испортился) — нужен новый IP/сервер")
fi

# статус + лог
if [ ${#problems[@]} -eq 0 ]; then
  status=OK; msg=""; log "OK (exit=$exit_ip loc=${loc:-?})"
else
  status=BAD; msg=$(printf '%s; ' "${problems[@]}"); log "BAD: $msg(exit=${exit_ip:-none} loc=${loc:-?})"
fi

# алерт при смене статуса OK<->BAD
prev=$(cat "$STATE" 2>/dev/null || echo OK)
echo "$status" > "$STATE"
if [ -f "$ALERT_CONF" ]; then
  # shellcheck disable=SC1090
  . "$ALERT_CONF"
  send() { curl -s --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="$1" >/dev/null 2>&1; }
  if [ "$status" = "BAD" ] && [ "$prev" != "BAD" ]; then
    send "🔴 [$SERVER_LABEL] $SERVER_IP: $msg"
  elif [ "$status" = "OK" ] && [ "$prev" = "BAD" ]; then
    send "🟢 [$SERVER_LABEL] $SERVER_IP восстановлен (exit=$exit_ip, loc=$loc)"
  fi
fi
