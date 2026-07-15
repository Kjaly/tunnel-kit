#!/bin/bash
# Включает Telegram-алерты для health-check: setup-telegram-alert.sh <BOT_TOKEN>
# Заранее: 1) создай бота у @BotFather -> получишь токен; 2) напиши боту любое сообщение.
# Токен вводится ТОЛЬКО на сервере (не в чат/не в git).
set -eu
TOKEN="${1:?Использование: setup-telegram-alert.sh <BOT_TOKEN>}"
echo "Ищу chat_id (ты уже написал боту?)..."
CHAT_ID=$(curl -s --max-time 10 "https://api.telegram.org/bot$TOKEN/getUpdates" \
  | grep -oE '"chat":\{"id":-?[0-9]+' | grep -oE '\-?[0-9]+' | tail -1)
if [ -z "${CHAT_ID:-}" ]; then
  echo "❌ Не нашёл chat_id. Отправь боту любое сообщение и запусти снова."
  exit 1
fi
umask 077
printf 'BOT_TOKEN=%s\nCHAT_ID=%s\n' "$TOKEN" "$CHAT_ID" > /root/vpn-alert.conf
chmod 600 /root/vpn-alert.conf
curl -s --max-time 10 "https://api.telegram.org/bot$TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" -d text="✅ tunnel-kit: алерты подключены. Сюда будут приходить уведомления о сбоях VPN." >/dev/null
echo "✅ Готово. chat_id=$CHAT_ID, конфиг /root/vpn-alert.conf (600). Тест-сообщение отправлено."
