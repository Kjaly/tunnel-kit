#!/bin/bash
# Ставит интерактивный Telegram-бот tunnel-kit: пользователь vpnbot (непривилегированный),
# root-хелпер vpnctl.sh (только через sudo с фиксированным whitelist), systemd-сервис.
#
#   scp -r scripts/ root@СЕРВЕР:/root/tunnel-kit-scripts/
#   ssh root@СЕРВЕР 'cd /root/tunnel-kit-scripts && bash install-vpn-bot.sh'
#
# Предварительно: install-traffic-monitor.sh (Stats API, коллектор, users.json-совместимые
# скрипты) и настроенный /root/vpn-alert.conf (BOT_TOKEN, CHAT_ID) — см. setup-telegram-alert.sh.
# Идемпотентен: повторный запуск обновляет бинарники и не дублирует конфиг/sudoers/юниты.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
CFG=/usr/local/etc/xray/config.json
ALERT_CONF=/root/vpn-alert.conf
USERS_FILE=/var/lib/vpn-usage/users.json
BOTCONF=/etc/vpnbot/bot.conf
SUDOERS=/etc/sudoers.d/vpnbot

for f in vpnctl.sh vpnbot.py; do
  [ -f "$SRC/$f" ] || { echo "❌ рядом нет $f — скопируй всю папку scripts/"; exit 1; }
done
command -v jq >/dev/null      || { echo "❌ нужен jq: apt-get install -y jq"; exit 1; }
command -v python3 >/dev/null || { echo "❌ нужен python3"; exit 1; }
command -v sudo >/dev/null    || { echo "❌ нужен sudo"; exit 1; }
command -v visudo >/dev/null  || { echo "❌ нужен visudo (пакет sudo)"; exit 1; }
[ -f "$CFG" ] || { echo "❌ не найден $CFG — сначала настрой xray"; exit 1; }
command -v qrencode >/dev/null || echo "⚠️  qrencode не найден — /qr работать не будет: apt-get install -y qrencode"

# ── системный пользователь vpnbot: без шелла, без домашней директории ──
if ! id -u vpnbot >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin --user-group vpnbot
  echo "✅ пользователь vpnbot создан"
else
  echo "ℹ️  пользователь vpnbot уже есть"
fi
usermod -aG systemd-journal vpnbot   # только чтение journalctl (для /logs), без root

# ── бинарники ──
install -m 700 -o root -g root "$SRC/vpnctl.sh" /usr/local/bin/vpnctl.sh
install -m 755 -o root -g root "$SRC/vpnbot.py"  /usr/local/bin/vpnbot.py
echo "✅ vpnctl.sh (700 root) и vpnbot.py (755 root) в /usr/local/bin"

# ── /etc/vpnbot/bot.conf: отдельный конфиг, т.к. /root закрыт для vpnbot на уровне каталога (700) ──
mkdir -p /etc/vpnbot
touch "$BOTCONF"
if ! grep -q '^BOT_TOKEN=' "$BOTCONF"; then
  # shellcheck disable=SC1090
  [ -f "$ALERT_CONF" ] && . "$ALERT_CONF"
  PRIMARY_EMAIL=$(jq -r '[.inbounds[]? | select(.protocol=="vless") | .settings.clients[]?.email][0] // ""' "$CFG" 2>/dev/null)
  cat >> "$BOTCONF" <<EOF
BOT_TOKEN=${BOT_TOKEN:-}
ALLOWED_CHAT_IDS=${CHAT_ID:-}
SERVER_LABEL=${SERVER_LABEL:-$(hostname -s)}
SERVER_IP=${SERVER_IP:-}
PRIMARY_EMAIL=${PRIMARY_EMAIL}
IFACE=eth0
EOF
  echo "✅ $BOTCONF создан (BOT_TOKEN/CHAT_ID — копия из $ALERT_CONF)"
else
  echo "ℹ️  $BOTCONF уже настроен — не трогаю (ALLOWED_CHAT_IDS правь вручную при необходимости)"
fi
chown vpnbot:vpnbot "$BOTCONF"
chmod 600 "$BOTCONF"

# ── users.json: сидируем текущими клиентами config.json, если ещё нет ──
mkdir -p /var/lib/vpn-usage
if [ ! -s "$USERS_FILE" ]; then
  jq -n --slurpfile cfg "$CFG" --arg d "$(date -u +%F)" '
    [$cfg[0].inbounds[]? | select(.protocol=="vless") | .settings.clients[]?.email // empty]
    | reduce .[] as $e ({}; .[$e] = {quota_gib: null, created: $d})
  ' > "$USERS_FILE"
  chmod 644 "$USERS_FILE"
  echo "✅ $USERS_FILE создан из текущих клиентов config.json"
else
  echo "ℹ️  $USERS_FILE уже есть — не трогаю"
fi

mkdir -p /var/lib/vpnbot
chown vpnbot:vpnbot /var/lib/vpnbot

# ── sudoers: фиксированный whitelist, без NOPASSWD ALL. Валидация ДО установки ──
TMP_SUDOERS=$(mktemp)
cat > "$TMP_SUDOERS" <<'EOF'
vpnbot ALL=(root) NOPASSWD: /usr/local/bin/vpnctl.sh adduser *
vpnbot ALL=(root) NOPASSWD: /usr/local/bin/vpnctl.sh deluser *
vpnbot ALL=(root) NOPASSWD: /usr/local/bin/vpnctl.sh set-quota *
vpnbot ALL=(root) NOPASSWD: /usr/local/bin/vpnctl.sh restart
vpnbot ALL=(root) NOPASSWD: /usr/local/bin/vpnctl.sh backup
EOF
if visudo -c -f "$TMP_SUDOERS" >/dev/null 2>&1; then
  install -m 440 -o root -g root "$TMP_SUDOERS" "$SUDOERS"
  echo "✅ sudoers: $SUDOERS (visudo -c пройден)"
else
  echo "❌ sudoers-файл не прошёл проверку visudo — НЕ устанавливаю"; rm -f "$TMP_SUDOERS"; exit 1
fi
rm -f "$TMP_SUDOERS"

# ── systemd unit бота ──
cat > /etc/systemd/system/vpnbot.service <<'EOF'
[Unit]
Description=tunnel-kit interactive Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vpnbot
ExecStart=/usr/bin/python3 /usr/local/bin/vpnbot.py
Restart=always
RestartSec=5
# NoNewPrivileges НЕ ставим: процессу нужно право выполнять sudo -n vpnctl.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpnbot.service
sleep 1

echo "--- проверка ---"
if systemctl is-active --quiet vpnbot.service; then
  echo "✅ vpnbot.service активен"
else
  echo "❌ vpnbot не поднялся — смотри: journalctl -u vpnbot -n 50 --no-pager"
  journalctl -u vpnbot -n 20 --no-pager || true
  exit 1
fi
systemctl status vpnbot.service --no-pager -l | head -n 8

cat <<EOF

Полезное:
  journalctl -u vpnbot -f                 живые логи бота
  cat $BOTCONF                            токен/allowlist (600, только root)
  jq . $USERS_FILE                        квоты и метаданные пользователей
  visudo -c                               проверить весь sudoers после ручных правок

Если ALLOWED_CHAT_IDS пуст или не тот — впиши через запятую chat_id'ы, кому можно
писать боту командами, и перезапусти: systemctl restart vpnbot
Проверка: напиши боту /help из разрешённого чата.
EOF
