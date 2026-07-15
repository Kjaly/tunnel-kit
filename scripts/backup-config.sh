#!/bin/bash
# Бэкап критичных конфигов/ключей VPN-сервера в один архив (/root/backups).
# Запусти вручную или по systemd-таймеру. Архив содержит СЕКРЕТЫ — не пушь в git, не выноси с сервера в открытом виде.
set -u
DEST=/root/backups
mkdir -p "$DEST"; chmod 700 "$DEST"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DEST/tunnel-kit-$STAMP.tar.gz"

FILES=""
for p in \
  /usr/local/etc/xray/config.json \
  /root/sub-nodes.txt /root/sub-secret.txt /root/vpn-alert.conf \
  /etc/caddy/Caddyfile \
  /etc/ssh/sshd_config.d/00-hardening.conf /etc/ssh/sshd_config.d/99-hardening.conf \
  /etc/systemd/system/xray.service.d /etc/systemd/system/caddy.service.d \
  /etc/systemd/system/vpn-healthcheck.service /etc/systemd/system/vpn-healthcheck.timer \
  /etc/systemd/system/tunnel-check.service /etc/systemd/system/tunnel-check.timer \
  /usr/local/bin/vpn-healthcheck.sh /usr/local/bin/tunnel-check.sh \
  /var/www/sub \
  /etc/sysctl.d/99-xray.conf /etc/sysctl.d/99-xray-tuning.conf \
  /etc/ssh/sshd_config.d/00-hardening.conf ; do
  [ -e "$p" ] && FILES="$FILES $p"
done

tar czf "$OUT" $FILES 2>/dev/null
chmod 600 "$OUT"
# держим последние 5 бэкапов
ls -1t "$DEST"/tunnel-kit-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f

echo "✅ Бэкап: $OUT ($(du -h "$OUT" | cut -f1))"
echo "   Внутри: xray config+ключи, подписка, hardening, systemd-юниты, скрипты, sysctl."
echo "   Восстановление на чистом сервере: tar xzf <архив> -C / && systemctl daemon-reload && systemctl restart xray"
