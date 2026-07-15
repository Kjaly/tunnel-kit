# Необязательные улучшения

База (VLESS + Reality + раздельное туннелирование из [README](README.md)) работает и без этого.
Ниже — апгрейды, которые можно добавить по желанию: **каждый независим и необязателен**.

| Улучшение | Что даёт | Сложность | Нужен ли новый ресурс |
|-----------|----------|-----------|------------------------|
| [Подписка (одна авто-ссылка)](#1-subscription-сервер) | серверы обновляются на всех устройствах сами | средняя | нет |
| [Мониторинг + авто-восстановление](#2-мониторинг--авто-восстановление) | сам чинит упавший сервис, ведёт лог | низкая | нет |
| [Telegram-алерты](#3-telegram-алерты) | узнаёшь о сбое удалённо | низкая | бот Telegram |
| [Кросс-серверный чек туннеля](#4-сквозной-кросс-серверный-чек-туннеля) | ловит поломку Reality/dest, которую сервисный чек не видит | низкая | 2 сервера |
| [Бэкап конфигов](#5-бэкап-конфигов) | пересобрать сервер за минуты | низкая | нет |
| [Дальше](#6-что-ещё-можно) | несколько серверов, второй DoH, XHTTP | разная | зависит |

---

## 1. Subscription-сервер

**Проблема:** при смене узла/ключа приходится вручную обновлять vless-ссылку на каждом устройстве (легко ошибиться — обрезать после `?`, потерять `sid`).

**Решение:** сервер раздаёт по секретному URL base64-список узлов, а Shadowrocket сам его периодически перекачивает (Auto Background Update). Правишь список на сервере — у всех клиентов обновилось.

**Как поднять (на том же VPS):**

1. Валидный TLS без покупки домена — через `sslip.io` (`<IP>.sslip.io` резолвится в твой IP) + Caddy (авто Let's Encrypt):
   ```bash
   # ставим Caddy (официальный репозиторий)
   apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
   curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
   curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list
   apt update && apt install -y caddy
   ```
2. Секретный путь + файл узлов:
   ```bash
   SECRET=$(openssl rand -hex 12); echo "$SECRET" > /root/sub-secret.txt
   mkdir -p /var/www/sub/$SECRET
   # положи свои vless-ссылки (по одной на строку) в /root/sub-nodes.txt, затем:
   base64 -w0 /root/sub-nodes.txt > /var/www/sub/$SECRET/nodes
   chown -R caddy:caddy /var/www/sub
   ```
3. Caddyfile (`/etc/caddy/Caddyfile`), подставь свой IP и порт ACME:
   ```
   { admin off }
   <IP>.sslip.io:8443 {
       root * /var/www/sub
       file_server
   }
   ```
   ```bash
   ufw allow 80/tcp    # для выпуска сертификата ACME
   ufw allow 8443/tcp  # порт подписки
   systemctl restart caddy
   ```
4. URL подписки: `https://<IP>.sslip.io:8443/<SECRET>/nodes`
   В Shadowrocket: «+» → Type **Subscribe** → вставь URL → Save (сертификат валидный, «Allow Insecure» не нужен).

**Обновление узлов:** правь `/root/sub-nodes.txt` → `base64 -w0 /root/sub-nodes.txt > /var/www/sub/$(cat /root/sub-secret.txt)/nodes`.

**Безопасность:** URL подписки = доступ к твоему VPN. Не делись, не пушь в git. Если утёк — смени секрет (новый `openssl rand -hex 12` + переименуй папку).

**Ограничение:** авто-обновляются **узлы**. Правила (маршрутизацию) Shadowrocket из URL тянет разово — обновляй пере-загрузкой при изменении.

---

## 2. Мониторинг + авто-восстановление

Каждые 5 минут проверяет xray (и подписку, если есть), чинит упавший сервис, ведёт лог, ловит порчу IP (регион OpenAI стал RU). Скрипт: [`scripts/vpn-healthcheck.sh`](scripts/vpn-healthcheck.sh).

```bash
# 1) впиши SERVER_IP в начале скрипта, затем:
cp scripts/vpn-healthcheck.sh /usr/local/bin/ && chmod +x /usr/local/bin/vpn-healthcheck.sh

# 2) xray и caddy — авто-рестарт при падении
#    (у официального xray.service уже Restart=on-failure; для caddy добавь:)
mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nRestart=always\nRestartSec=5\n' > /etc/systemd/system/caddy.service.d/restart.conf

# 3) systemd service + timer
cat > /etc/systemd/system/vpn-healthcheck.service <<'EOF'
[Unit]
Description=VPN health check and auto-recovery
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-healthcheck.sh
EOF
cat > /etc/systemd/system/vpn-healthcheck.timer <<'EOF'
[Unit]
Description=Run VPN health check every 5 min
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOF

# 4) ротация лога + запуск
printf '/var/log/vpn-health.log { weekly rotate 4 compress missingok notifempty copytruncate }\n' > /etc/logrotate.d/vpn-health
systemctl daemon-reload && systemctl enable --now vpn-healthcheck.timer && systemctl restart caddy
```

Проверка: `systemctl list-timers vpn-healthcheck.timer` и `tail /var/log/vpn-health.log`.
Тест восстановления: `systemctl stop xray && /usr/local/bin/vpn-healthcheck.sh` — должен поднять xray обратно.

---

## 3. Telegram-алерты

Чтобы узнавать о сбое удалённо. Работает поверх мониторинга (п.2). Скрипт: [`scripts/setup-telegram-alert.sh`](scripts/setup-telegram-alert.sh).

1. Создай бота у **@BotFather** → получишь токен `123456:ABC...`.
2. Напиши своему боту любое сообщение.
3. На сервере (токен вводится ТОЛЬКО тут, не в чат/не в git):
   ```bash
   cp scripts/setup-telegram-alert.sh /root/ && chmod +x /root/setup-telegram-alert.sh
   /root/setup-telegram-alert.sh 123456:ABC...
   ```
   Скрипт сам найдёт chat_id, включит алерты, пришлёт тест. Уведомления шлются при смене статуса OK↔BAD (без спама).

Если токен где-то засветился — перевыпусти его в **@BotFather → /revoke** и запусти скрипт заново.

---

## 4. Сквозной кросс-серверный чек туннеля

Сервисный health-check (п.2) видит, что xray *жив*, но не что через него реально ходит трафик — если сломается Reality/`dest` (сервис активен, а туннель не работает), он это пропустит. Решение при 2+ серверах: каждый сервер периодически поднимает временный xray-клиент к **другому** серверу и проверяет реальный выход (`curl ifconfig == IP пира`). Крест-накрест: A проверяет B, B проверяет A (обходит hairpin-NAT на своём же IP).

Скрипт: [`scripts/tunnel-check.sh`](scripts/tunnel-check.sh) — заполни вверху параметры **пира** (его IP, UUID, publicKey, SNI, shortId — всё из vless-ссылки пира; `pbk` публичен).

```bash
cp scripts/tunnel-check.sh /usr/local/bin/ && chmod +x /usr/local/bin/tunnel-check.sh
# systemd service + timer (каждые 15 мин) — по аналогии с п.2
```

При поломке туннеля до пира прилетит алерт `🔴 Туннель до [PEER] не работает` (использует тот же `/root/vpn-alert.conf`, что и п.3). Именно этот чек ловит класс «Reality/dest сломан, а сервис жив».

---

## 5. Бэкап конфигов

Один архив со всем, что нужно для пересборки сервера за минуты: xray config+ключи, подписка, hardening, systemd-юниты, скрипты, sysctl. Скрипт: [`scripts/backup-config.sh`](scripts/backup-config.sh).

```bash
cp scripts/backup-config.sh /usr/local/bin/ && chmod +x /usr/local/bin/backup-config.sh
/usr/local/bin/backup-config.sh           # -> /root/backups/tunnel-kit-<дата>.tar.gz (600, хранит 5 последних)
# опц. weekly-таймер: systemd service+timer с OnCalendar=weekly
```

Восстановление на чистом сервере: `tar xzf <архив> -C / && systemctl daemon-reload && systemctl restart xray`.
Архив содержит **приватные ключи** — держи его только на сервере (600), не пушь в git.

> ⚠️ После крупных изменений полезно проверить **выживание после ребута**: `reboot`, затем убедись, что xray, подписка, таймеры и swap поднялись сами (`systemctl is-active ...`).

---

## 6. Что ещё можно

- **Несколько серверов + failover** — 2–3 VPS у разных хостеров, все узлы в одной подписке; при блокировке IP переключаешься в приложении. Резидентная устойчивость.
- **Второй независимый DoH** в клиенте — резерв, если основной DoH недоступен (не оставляй fallback на `system` — утечка в DNS провайдера).
- **XHTTP-транспорт** вторым профилем — против поведенческого анализа ТСПУ (2026). Сложнее: нужен nginx-SNI перед xray либо отдельный порт, и тест на устройстве. Текущий TCP+Reality+Vision оставляй как основной.
- **swap** на 1 GB-ноде — страховка от OOM: `fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` + строка в `/etc/fstab`.

Каждое — независимо. Бери то, что нужно.
