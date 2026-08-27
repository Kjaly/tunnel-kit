#!/bin/bash
# Единственная точка привилегированных мутаций для vpnbot.py.
# Вызывается ТОЛЬКО через `sudo -n` от пользователя vpnbot — см. /etc/sudoers.d/vpnbot
# (создаётся install-vpn-bot.sh, фиксированный whitelist подкоманд, без NOPASSWD ALL).
#
#   vpnctl.sh adduser <email>            новый VLESS-клиент
#   vpnctl.sh deluser <email>             удалить клиента
#   vpnctl.sh set-quota <email> <gib>     личная квота трафика/мес; 0 = снять лимит
#   vpnctl.sh restart                     systemctl restart xray + проверка :443
#   vpnctl.sh backup                      прогнать backup-config.sh
#
# adduser/deluser меняют /usr/local/etc/xray/config.json по проверенному паттерну
# (см. enable-xray-stats.sh): бэкап -> jq-трансформация -> `xray run -test` ->
# install -> restart -> проверка :443 -> автооткат при провале.
set -euo pipefail

CFG=/usr/local/etc/xray/config.json
USERS=/var/lib/vpn-usage/users.json

# email из Telegram-команды: буквы/цифры/._@- , не пусто, разумный потолок длины
EMAIL_RE='^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$'
GIB_RE='^[0-9]+(\.[0-9]+)?$'

die() { echo "❌ $1" >&2; exit 1; }
validate_email() { [[ "$1" =~ $EMAIL_RE ]] || die "недопустимый email: $1"; }

ensure_users_file() {
  [ -s "$USERS" ] || { install -m 644 -o root -g root /dev/null "$USERS"; echo '{}' > "$USERS"; }
}

client_exists() {
  jq -e --arg e "$1" '[.inbounds[]?.settings.clients[]? | select(.email==$e)] | length>0' "$CFG" >/dev/null
}

# Применяет уже готовый (прошедший jq) конфиг: бэкап -> validate -> install -> restart -> проверка -> откат
apply_config() {
  local tmp="$1" stamp bak
  stamp=$(date +%Y%m%d-%H%M%S)
  bak="${CFG}.bak.${stamp}"

  if ! xray run -test -config "$tmp"; then
    rm -f "$tmp"
    die "новый конфиг не прошёл xray run -test — отменено, сервис не трогали"
  fi

  cp -a "$CFG" "$bak"
  install -m 644 -o root -g root "$tmp" "$CFG"
  rm -f "$tmp"
  systemctl restart xray
  sleep 2

  if systemctl is-active --quiet xray && ss -tln | grep -q ':443 '; then
    echo "✅ xray перезапущен, :443 слушает (бэкап: $bak)"
  else
    echo "⚠️  проблема после рестарта — откатываю на $bak" >&2
    cp -a "$bak" "$CFG"
    systemctl restart xray; sleep 2
    if systemctl is-active --quiet xray && ss -tln | grep -q ':443 '; then
      die "конфиг откачен на предыдущую версию, xray снова работает"
    else
      die "КРИТИЧНО: xray не поднимается даже на старом конфиге — нужна ручная проверка на сервере"
    fi
  fi
}

CMD="${1:-}"
case "$CMD" in
  adduser)
    EMAIL="${2:?Использование: vpnctl.sh adduser <email>}"
    validate_email "$EMAIL"
    client_exists "$EMAIL" && die "пользователь $EMAIL уже существует"

    UUID=$(cat /proc/sys/kernel/random/uuid)
    TMP=$(mktemp /tmp/xray-cfg.XXXXXX.json)
    jq --arg e "$EMAIL" --arg id "$UUID" '
      .inbounds |= map(if .protocol=="vless" then
        .settings.clients += [{"id":$id,"email":$e,"flow":"xtls-rprx-vision"}]
      else . end)
    ' "$CFG" > "$TMP"
    apply_config "$TMP"

    ensure_users_file
    jq --arg e "$EMAIL" --arg d "$(date -u +%F)" \
      '.[$e] = {quota_gib: null, created: $d}' "$USERS" > "$USERS.tmp" && mv "$USERS.tmp" "$USERS"
    echo "✅ пользователь $EMAIL добавлен, uuid=$UUID"
    ;;

  deluser)
    EMAIL="${2:?Использование: vpnctl.sh deluser <email>}"
    validate_email "$EMAIL"
    client_exists "$EMAIL" || die "пользователь $EMAIL не найден"

    TMP=$(mktemp /tmp/xray-cfg.XXXXXX.json)
    jq --arg e "$EMAIL" '
      .inbounds |= map(if .protocol=="vless" then
        .settings.clients |= map(select(.email != $e))
      else . end)
    ' "$CFG" > "$TMP"
    apply_config "$TMP"

    ensure_users_file
    jq --arg e "$EMAIL" 'del(.[$e])' "$USERS" > "$USERS.tmp" && mv "$USERS.tmp" "$USERS"
    echo "✅ пользователь $EMAIL удалён (история расхода в /var/lib/vpn-usage/*.json сохранена)"
    ;;

  set-quota)
    EMAIL="${2:?Использование: vpnctl.sh set-quota <email> <gib>}"
    GIB="${3:?Использование: vpnctl.sh set-quota <email> <gib>}"
    validate_email "$EMAIL"
    [[ "$GIB" =~ $GIB_RE ]] || die "квота должна быть числом (ГиБ); 0 = снять лимит"
    client_exists "$EMAIL" || die "пользователь $EMAIL не найден в config.json"

    ensure_users_file
    jq --arg e "$EMAIL" --arg g "$GIB" --arg d "$(date -u +%F)" '
      .[$e] = ((.[$e] // {created: $d}) + {quota_gib: (if ($g|tonumber)==0 then null else ($g|tonumber) end)})
    ' "$USERS" > "$USERS.tmp" && mv "$USERS.tmp" "$USERS"
    if [ "$GIB" = "0" ]; then echo "✅ лимит для $EMAIL снят"; else echo "✅ квота $EMAIL = $GIB ГиБ/мес"; fi
    ;;

  restart)
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray && ss -tln | grep -q ':443 '; then
      echo "✅ xray перезапущен, :443 слушает"
    else
      die "xray не поднялся после рестарта — нужна ручная проверка на сервере"
    fi
    ;;

  backup)
    [ -x /usr/local/bin/backup-config.sh ] || die "не найден /usr/local/bin/backup-config.sh"
    /usr/local/bin/backup-config.sh
    ;;

  *)
    die "команды: adduser <email> | deluser <email> | set-quota <email> <gib> | restart | backup"
    ;;
esac
