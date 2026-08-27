#!/bin/bash
# Ставит учёт трафика: коллектор per-user статистики + алерт по месячной квоте.
# Запускать НА СЕРВЕРЕ, из папки, где лежат vpn-usage-collect.sh и vpn-traffic-alert.sh.
#
#   scp -r scripts/ root@СЕРВЕР:/root/tunnel-kit-scripts/
#   ssh root@СЕРВЕР 'cd /root/tunnel-kit-scripts && bash install-traffic-monitor.sh'
#
# Предварительно: enable-xray-stats.sh (Stats API) и настроенный Telegram
# (setup-telegram-alert.sh создаёт /root/vpn-alert.conf с BOT_TOKEN и CHAT_ID).
#
# Идемпотентен: повторный запуск обновляет скрипты и не дублирует конфиг.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
CONF=/root/vpn-alert.conf
QUOTA_GIB="${QUOTA_GIB:-1000}"   # ГиБ/мес, включённых в тариф

for f in vpn-usage-collect.sh vpn-traffic-alert.sh; do
  [ -f "$SRC/$f" ] || { echo "❌ рядом нет $f — скопируй всю папку scripts/"; exit 1; }
done
command -v jq >/dev/null || { echo "❌ нужен jq: apt-get install -y jq"; exit 1; }
command -v vnstat >/dev/null || { echo "❌ нужен vnstat: apt-get install -y vnstat && systemctl enable --now vnstat"; exit 1; }
systemctl is-active --quiet vnstat || echo "⚠️  демон vnstat не запущен: systemctl enable --now vnstat"

mkdir -p /var/lib/vpn-usage
install -m 755 -o root -g root "$SRC/vpn-usage-collect.sh"  /usr/local/bin/vpn-usage-collect.sh
install -m 755 -o root -g root "$SRC/vpn-traffic-alert.sh"  /usr/local/bin/vpn-traffic-alert.sh
echo "✅ скрипты в /usr/local/bin"

# ── параметры в общий конфиг алертов (не перетираем существующие) ──
# Держим их в конфиге, а не в скрипте: тогда переустановка из репо не затрёт
# имя и IP сервера плейсхолдерами.
touch "$CONF"; chmod 600 "$CONF"
if ! grep -q '^SERVER_LABEL=' "$CONF"; then
  DETECTED_IP=$(curl -4 -s --max-time 10 https://ifconfig.me || true)
  cat >> "$CONF" <<EOF
# ── идентификация сервера в алертах ──
SERVER_LABEL=${SERVER_LABEL:-$(hostname -s)}
SERVER_IP=${SERVER_IP:-${DETECTED_IP:-YOUR_SERVER_IP}}
EOF
  echo "✅ SERVER_LABEL/SERVER_IP добавлены в $CONF"
fi
if ! grep -q '^QUOTA_GIB=' "$CONF"; then
  cat >> "$CONF" <<EOF
# ── квота исходящего трафика хостера, ГиБ/мес ──
QUOTA_GIB=${QUOTA_GIB}
# Поправка за период до старта vnStat. Применяется только к указанному месяцу
# и отключается автоматически при его смене. Пример: TRAFFIC_OFFSET_MONTH=2026-08
TRAFFIC_OFFSET_MONTH=
TRAFFIC_OFFSET_GIB=0
EOF
  echo "✅ QUOTA_GIB=${QUOTA_GIB} добавлен в $CONF"
else
  echo "ℹ️  QUOTA_GIB уже есть в $CONF — не трогаю"
fi

# ── systemd: один таймер на 10 минут — сбор статистики + проверка порога ──
cat > /etc/systemd/system/vpn-usage.service <<'EOF'
[Unit]
Description=Collect per-user VPN traffic and check monthly quota
After=xray.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-usage-collect.sh
ExecStart=/usr/local/bin/vpn-traffic-alert.sh
EOF

cat > /etc/systemd/system/vpn-usage.timer <<'EOF'
[Unit]
Description=Run VPN usage collector every 10 min
[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
AccuracySec=1min
[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/vpn-digest.service <<'EOF'
[Unit]
Description=Weekly VPN traffic/incidents digest
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-traffic-alert.sh --digest
EOF

cat > /etc/systemd/system/vpn-digest.timer <<'EOF'
[Unit]
Description=Run weekly VPN digest every Monday 09:00 UTC
[Timer]
OnCalendar=Mon *-*-* 09:00:00
Persistent=true
AccuracySec=5min
[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/vpn-monthly.service <<'EOF'
[Unit]
Description=Monthly VPN traffic summary (previous calendar month)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-traffic-alert.sh --monthly
EOF

cat > /etc/systemd/system/vpn-monthly.timer <<'EOF'
[Unit]
Description=Run monthly VPN summary on the 1st, 09:00 UTC
[Timer]
OnCalendar=*-*-01 09:00:00
Persistent=true
AccuracySec=5min
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-usage.timer
systemctl enable --now vpn-digest.timer
systemctl enable --now vpn-monthly.timer

echo "--- проверка ---"
/usr/local/bin/vpn-usage-collect.sh && echo "коллектор ok"
/usr/local/bin/vpn-traffic-alert.sh --dry
systemctl list-timers vpn-usage.timer vpn-digest.timer vpn-monthly.timer --no-pager

cat <<'EOF'

Полезное:
  vpn-traffic-alert.sh --report          отчёт в Telegram по требованию
  vpn-traffic-alert.sh --digest          недельная сводка вне очереди (обычно шлётся по пн 09:00 UTC)
  vpn-traffic-alert.sh --monthly         итоги прошлого месяца вне очереди (обычно 1-го числа 09:00 UTC)
  jq . /var/lib/vpn-usage/$(date -u +%Y-%m).json    расход по пользователям
  vnstat -d ; vnstat -m ; vnstat -l -i eth0
EOF
