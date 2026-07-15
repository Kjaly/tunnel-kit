#!/bin/bash
# Сквозной end-to-end чек туннеля: поднимает временный xray-клиент к ДРУГОМУ серверу (пиру)
# и проверяет, что через него реально ходит трафик (curl ifconfig == IP пира).
# Ловит поломку Reality/dest на пире, которую сервисный health-check не видит.
# Ставится на каждый сервер крест-накрест (DO проверяет TW, TW проверяет DO), обходя hairpin.
# Запускается systemd-таймером (напр. каждые 15 мин).
set -u

# ── параметры ПИРА (другого сервера) — заполни при установке ─────────
SELF_LABEL="MY-VPN"                 # имя ЭТОГО сервера
PEER_LABEL="PEER-VPN"              # имя пира
PEER_IP="PEER_SERVER_IP"
PEER_UUID="PEER_UUID"
PEER_PBK="PEER_PUBLIC_KEY"
PEER_SNI="PEER_REALITY_SNI"
PEER_SID="PEER_SHORT_ID"
PORT=10900
# ────────────────────────────────────────────────────────────────────

LOG=/var/log/vpn-tunnel.log
STATE=/run/vpn-tunnel.state
ALERT_CONF=/root/vpn-alert.conf
ts(){ date "+%Y-%m-%d %H:%M:%S"; }

CFG=$(mktemp --suffix=.json)   # .json обязателен: иначе xray не определит формат конфига
cat > "$CFG" <<EOF
{
  "log": {"loglevel":"error"},
  "inbounds":[{"port":$PORT,"listen":"127.0.0.1","protocol":"socks","settings":{"udp":false}}],
  "outbounds":[{
    "protocol":"vless",
    "settings":{"vnext":[{"address":"$PEER_IP","port":443,"users":[{"id":"$PEER_UUID","flow":"xtls-rprx-vision","encryption":"none"}]}]},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"$PEER_SNI","fingerprint":"chrome","publicKey":"$PEER_PBK","shortId":"$PEER_SID"}}
  }]
}
EOF
xray -c "$CFG" >/dev/null 2>&1 &
XPID=$!
sleep 3
GOT=$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:$PORT https://ifconfig.me 2>/dev/null)
kill "$XPID" 2>/dev/null; rm -f "$CFG"

if [ "$GOT" = "$PEER_IP" ]; then status=OK; else status=BAD; fi
echo "$(ts) $status (peer=$PEER_LABEL got=${GOT:-none} want=$PEER_IP)" >> "$LOG"

now(){ date "+%d.%m %H:%M"; }
prev=$(cat "$STATE" 2>/dev/null || echo OK); echo "$status" > "$STATE"
if [ -f "$ALERT_CONF" ]; then
  # shellcheck disable=SC1090
  . "$ALERT_CONF"
  send(){ curl -s --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode=HTML --data-urlencode "text=$1" >/dev/null 2>&1; }
  if [ "$status" = "BAD" ] && [ "$prev" != "BAD" ]; then
    send "🔴 <b>Туннель мёртв · ${PEER_LABEL}</b>
🔗 проверка с <b>${SELF_LABEL}</b> → <code>${PEER_IP}</code>
<blockquote>Не тоннелируется через ${PEER_LABEL} — вероятно сломан Reality/dest</blockquote>
🕐 $(now)"
  elif [ "$status" = "OK" ] && [ "$prev" = "BAD" ]; then
    send "🟢 <b>Туннель восстановлен · ${PEER_LABEL}</b>
🔗 проверка с <b>${SELF_LABEL}</b>
🕐 $(now)"
  fi
fi
