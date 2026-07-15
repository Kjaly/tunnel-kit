#!/bin/bash
# Health-check + авто-восстановление VPN. systemd-таймер каждые 5 мин.
# Проверяет xray (и подписку/caddy, если есть), исходящий интернет, регион OpenAI.
# Авто-рестарт сервиса. Telegram-алерты 3 уровней: 🟢 ок · 🟡 авто-починка · 🔴 критично.
set -u

# ── настрой под себя ────────────────────────────────────────────────
SERVER_LABEL="MY-VPN"               # понятное имя сервера для алертов (напр. DO-AMS)
SERVER_IP="YOUR_SERVER_IP"          # публичный IP сервера
SUB_PORT="8443"                     # порт подписки (если поднимал subscription-сервер; иначе не важно)
# ────────────────────────────────────────────────────────────────────

LOG=/var/log/vpn-health.log
STATE=/run/vpn-health.state
ALERT_CONF=/root/vpn-alert.conf
SUB_SECRET=$(cat /root/sub-secret.txt 2>/dev/null)
SSLIP="${SERVER_IP}.sslip.io"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
now() { date "+%d.%m %H:%M"; }
log() { echo "$(ts) $1" >> "$LOG"; }
flag() { case "$1" in NL) echo 🇳🇱;; RU) echo 🇷🇺;; DE) echo 🇩🇪;; FI) echo 🇫🇮;; US) echo 🇺🇸;; GB) echo 🇬🇧;; FR) echo 🇫🇷;; NL) echo 🇳🇱;; "") echo 🌍;; *) echo "🌍 $1";; esac; }

problems=(); crit=0; warn=0

# 1. xray активен и слушает 443
if ! systemctl is-active --quiet xray || ! ss -tln | grep -q ':443 '; then
  systemctl restart xray; sleep 2
  if systemctl is-active --quiet xray && ss -tln | grep -q ':443 '; then
    warn=1; problems+=("xray был недоступен → перезапущен, снова работает")
  else
    crit=1; problems+=("xray НЕ поднимается после рестарта — нужна ручная проверка")
  fi
fi

# 2. (опц.) caddy + подписка
if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
  if ! systemctl is-active --quiet caddy; then systemctl restart caddy; sleep 2; warn=1; problems+=("caddy был down → перезапущен"); fi
  if [ -n "$SUB_SECRET" ]; then
    code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 --resolve "$SSLIP:$SUB_PORT:127.0.0.1" "https://$SSLIP:$SUB_PORT/$SUB_SECRET/nodes")
    [ "$code" != "200" ] && { warn=1; problems+=("подписка не отдаётся (код $code)"); }
  fi
fi

# 3. исходящий интернет + регион OpenAI (форс IPv4)
exit_ip=$(curl -4 -s --max-time 10 https://ifconfig.me)
loc=""
if [ -z "$exit_ip" ]; then
  crit=1; problems+=("нет исходящего интернета")
else
  loc=$(curl -4 -s --max-time 10 https://chatgpt.com/cdn-cgi/trace | grep "^loc=" | cut -d= -f2 | tr -d "\r")
  [ "$loc" = "RU" ] && { crit=1; problems+=("OpenAI видит регион RU — нужен новый IP/сервер"); }
fi

# уровень
if [ "$crit" = 1 ]; then sev=crit; elif [ "$warn" = 1 ]; then sev=warn; else sev=ok; fi
detail=$(printf '%s; ' "${problems[@]}")
log "${sev^^} ${detail}(exit=${exit_ip:-none} loc=${loc:-?})"

FL=$(flag "$loc")
prev=$(cat "$STATE" 2>/dev/null || echo ok); echo "$sev" > "$STATE"
if [ -f "$ALERT_CONF" ]; then
  # shellcheck disable=SC1090
  . "$ALERT_CONF"
  send() { curl -s --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode=HTML --data-urlencode "text=$1" >/dev/null 2>&1; }
  if [ "$sev" = "crit" ] && [ "$prev" != "crit" ]; then
    send "🔴 <b>СБОЙ · ${SERVER_LABEL}</b>
🖥 <code>${SERVER_IP}</code> · ${FL}
<blockquote>${detail}</blockquote>
🕐 $(now)"
  elif [ "$sev" = "warn" ] && [ "$prev" = "ok" ]; then
    send "🟡 <b>Авто-починка · ${SERVER_LABEL}</b>
🖥 <code>${SERVER_IP}</code> · ${FL}
<blockquote>${detail}</blockquote>
🕐 $(now)"
  elif [ "$sev" != "crit" ] && [ "$prev" = "crit" ]; then
    send "🟢 <b>Восстановлен · ${SERVER_LABEL}</b>
🖥 <code>${SERVER_IP}</code> · ${FL}
🕐 $(now)"
  fi
fi
