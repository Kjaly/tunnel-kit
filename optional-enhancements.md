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
| [Учёт трафика по пользователям](#6-учёт-трафика-по-пользователям) | видно, кто сколько съел; алерт до овереджа хостера | средняя | нет |
| [Интерактивный Telegram-бот](#7-интерактивный-telegram-бот) | управление сервером из чата: клиенты, ссылки, квоты | средняя | бот Telegram |
| [Перенос на роутер (XKeen)](#8-перенос-на-роутер-xkeen) | VPN для всей домашней сети, а не по устройству · *гайд скоро* | высокая | роутер с Entware |
| [Дальше](#9-что-ещё-можно) | несколько серверов, второй DoH, XHTTP | разная | зависит |

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

При поломке туннеля до пира прилетит алерт `🔴 Туннель мёртв · [PEER]` (HTML-формат, тот же `/root/vpn-alert.conf`, что и п.3). Именно этот чек ловит класс «Reality/dest сломан, а сервис жив».

> Формат алертов: HTML (`parse_mode=HTML`) — жирный заголовок, IP моно-`code`, причина в `<blockquote>`, флаг страны. Уровни: 🟢 ок · 🟡 авто-починка (сам перезапустился) · 🔴 критично (нужна ручная проверка). Цвет текста Telegram не поддерживает — «цвет» передаётся эмодзи.

---

## 5. Бэкап конфигов

Один архив со всем, что нужно для пересборки сервера за минуты: xray config+ключи, подписка, hardening, systemd-юниты, скрипты, sysctl, а также учёт трафика (`/var/lib/vpn-usage` — история и квоты) и конфиг бота, если они ставились (п.6–7). Скрипт: [`scripts/backup-config.sh`](scripts/backup-config.sh).

```bash
cp scripts/backup-config.sh /usr/local/bin/ && chmod +x /usr/local/bin/backup-config.sh
/usr/local/bin/backup-config.sh           # -> /root/backups/tunnel-kit-<дата>.tar.gz (600, хранит 5 последних)
# опц. weekly-таймер: systemd service+timer с OnCalendar=weekly
```

Восстановление на чистом сервере: `tar xzf <архив> -C / && systemctl daemon-reload && systemctl restart xray`.
Архив содержит **приватные ключи** — держи его только на сервере (600), не пушь в git.

> ⚠️ После крупных изменений полезно проверить **выживание после ребута**: `reboot`, затем убедись, что xray, подписка, таймеры и swap поднялись сами (`systemctl is-active ...`).

---

## 6. Учёт трафика по пользователям

**Проблема:** у хостера включённый исходящий трафик конечен (у DigitalOcean на тарифе $6 — 1000 ГиБ/мес, дальше $0.01/ГиБ), а `vnstat` показывает только общую цифру по серверу. Кто именно её съел — непонятно, и узнаёшь ты об этом из счёта.

**Решение:** xray умеет считать трафик по каждому клиенту, если включить Stats API и повесить `email`-теги. Дальше коллектор раз в 10 минут забирает счётчики и копит помесячно, а отдельный скрипт следит за общей квотой хостера.

> Почему коллектор, а не чтение по требованию: счётчики xray живут в памяти и обнуляются при рестарте сервиса. Коллектор снимает их с `-reset` и накапливает в файл, поэтому перезапуск xray не стирает историю.

**Что понадобится:** `jq`, `vnstat` (демон запущен), настроенные Telegram-алерты (п.3 — из них берётся `/root/vpn-alert.conf`).

```bash
apt-get install -y jq vnstat && systemctl enable --now vnstat

# на локальной машине: закинуть скрипты на сервер
scp -r scripts/ root@СЕРВЕР:/root/tunnel-kit-scripts/

# на сервере
cd /root/tunnel-kit-scripts
bash enable-xray-stats.sh user@main     # Stats API + email-теги клиентам
QUOTA_GIB=1000 bash install-traffic-monitor.sh
```

[`enable-xray-stats.sh`](scripts/enable-xray-stats.sh) добавляет в конфиг `stats`/`api`/`policy`, поднимает служебный inbound на `127.0.0.1:10085` (наружу не торчит) и правило роутинга `api → api` первым в списке. Меняет `config.json` по безопасному паттерну: бэкап → `xray run -test` → рестарт → проверка `:443` → автооткат при провале. Идемпотентен.

[`install-traffic-monitor.sh`](scripts/install-traffic-monitor.sh) ставит три таймера:

| Таймер | Когда | Что делает |
|--------|-------|------------|
| `vpn-usage.timer` | каждые 10 мин | [`vpn-usage-collect.sh`](scripts/vpn-usage-collect.sh) + проверка порогов |
| `vpn-digest.timer` | пн 09:00 UTC | недельная сводка: расход, топ, инциденты из health-лога |
| `vpn-monthly.timer` | 1-го 09:00 UTC | итоги прошедшего календарного месяца |

Пороги предупреждений — 80% и 95% квоты. Месяц календарный по UTC: так же считает хостер и `vnStat` с `MonthRotate=1`.

**Ручные команды:**

```bash
vpn-traffic-alert.sh --report      # отчёт в Telegram по требованию
vpn-traffic-alert.sh --dry         # то же, но только в консоль
jq . /var/lib/vpn-usage/$(date -u +%Y-%m).json    # расход по пользователям
```

**Личные квоты:** если у клиента в `/var/lib/vpn-usage/users.json` проставлен лимит (это делает бот из п.7 командой `/quota`), коллектор сверяет расход с ним и присылает алерт с кнопкой «Отключить» — один раз в месяц на пользователя.

**Если vnStat запущен позже сервера** — первые дни месяца он не видел. Поправка задаётся в `/root/vpn-alert.conf` (`TRAFFIC_OFFSET_MONTH`, `TRAFFIC_OFFSET_GIB`) и сама отключается при смене месяца.

---

## 7. Интерактивный Telegram-бот

Тот же чат, куда падают алерты, но с командами: посмотреть статус, выдать ссылку новому человеку, поставить лимит, перезапустить xray — без SSH.

**Требует п.6** (Stats API и `users.json`) и настроенных алертов (п.3).

```bash
apt-get install -y jq qrencode          # qrencode — только для /qr
ssh root@СЕРВЕР 'cd /root/tunnel-kit-scripts && bash install-vpn-bot.sh'
# впиши, кому можно писать боту, и перезапусти:
#   ALLOWED_CHAT_IDS=<твой chat_id> в /etc/vpnbot/bot.conf
systemctl restart vpnbot && journalctl -u vpnbot -f
```

Проверка: напиши боту `/help` из разрешённого чата.

| Группа | Команды |
|--------|---------|
| Инфо | `/status` (xray, exit IP, регион, load/RAM/uptime), `/traffic` (квота, темп, прогноз), `/day`, `/month`, `/users`, `/top` |
| Доступ | `/link [имя]`, `/qr [имя]`, `/adduser <имя>`, `/deluser <имя>`, `/quota <имя> <ГиБ>` |
| Операции | `/restart`, `/logs`, `/backup` |

Удаление клиента и рестарт спрашивают подтверждение кнопкой.

**Как устроена безопасность** (это главное, ради чего тут два файла вместо одного):

- Бот [`vpnbot.py`](scripts/vpnbot.py) работает под системным пользователем `vpnbot` — без шелла, без домашней директории, не root. Сам он `config.json` не трогает.
- Все привилегированные операции идут через единственную точку — [`vpnctl.sh`](scripts/vpnctl.sh), вызываемый как `sudo -n vpnctl.sh <подкоманда>`. В `/etc/sudoers.d/vpnbot` прописан фиксированный whitelist из пяти подкоманд, никакого `NOPASSWD: ALL`. Файл проверяется `visudo -c` **до** установки.
- `vpnctl.sh` валидирует имя клиента регуляркой и правит конфиг тем же паттерном с автооткатом, что и `enable-xray-stats.sh`.
- Токен лежит в `/etc/vpnbot/bot.conf` (600, владелец `vpnbot`), а не в `/root/vpn-alert.conf`: каталог `/root` закрыт правами 700 — прочитать оттуда файл непривилегированный процесс не сможет, даже если дать права на сам файл.
- Кто может писать боту — список `ALLOWED_CHAT_IDS`. Пустой список означает, что команды не примет никто.

> `NoNewPrivileges` в юните намеренно не выставлен — с ним процесс не смог бы вызвать `sudo`. Ограничение здесь даёт whitelist в sudoers, а не флаг systemd.

---

## 8. Перенос на роутер (XKeen)

> [!NOTE]
> **Пошаговый гайд по установке — в работе.** Здесь пока только два конвертера: они снимают ручную работу и фиксируют ловушки, на которых спотыкаются все. Установка Entware на USB, выбор ветки для белого и серого IP и поведение при обновлении прошивки будут описаны отдельно — эту часть нельзя писать, не сверяясь с живым роутером.

Когда VPN переезжает с телефонов на роутер, раздельное туннелирование надо перенести из Shadowrocket в Xray на роутере. Два скрипта снимают ручную работу и обходят две тихие ловушки — обе выглядят как «всё настроено, но что-то глючит».

**Правила Shadowrocket → routing для Xray:**

```bash
python3 scripts/shadowrocket-to-xray.py ru-direct.list -o routing.json
# имя geo-базы на роутере может отличаться — проверь: ls /opt/etc/xray/dat
python3 scripts/shadowrocket-to-xray.py ru-direct.list --geoip-file geoip_v2fly.dat
```

> ⚠️ **`geoip:ru` в XKeen молча не работает.** Xray читает префикс `geoip:` строго из файла `geoip.dat`, а XKeen раскладывает базы под другими именами (`geoip_v2fly.dat` и подобные). Конфиг при этом валиден, роутер работает, ошибок в логе нет — просто правило не срабатывает, и весь российский трафик идёт через VPS. Обнаруживается это обычно тогда, когда банк просит подтвердить вход из другой страны. Правильная запись — `ext:geoip_v2fly.dat:ru`, её и генерирует [`shadowrocket-to-xray.py`](scripts/shadowrocket-to-xray.py).

**WireGuard `.conf` → статические маршруты роутера:**

```bash
python3 scripts/wg-conf-to-routes.py work.conf --home-subnet 192.168.1.0/24
python3 scripts/wg-conf-to-routes.py work.conf --format bat > routes.bat   # импорт в веб-интерфейсе
```

> ⚠️ **В Keenetic/Netcraze «Разрешённые подсети» (AllowedIPs) — это фильтр, а не таблица маршрутизации.** Импортировать `.conf` недостаточно: туннель поднимется, handshake пройдёт, а трафик в него не пойдёт — маршруты добавляются отдельно, по одному на подсеть. [`wg-conf-to-routes.py`](scripts/wg-conf-to-routes.py) генерирует их в трёх форматах (`bat` для массового импорта, `cli` для консоли роутера, `xkeen` для `ip_exclude.lst`) и заодно проверяет пересечения с домашней подсетью: маршрут `/32` на локальный адрес делает домашнее устройство недоступным, а выглядит это как «глючит Wi-Fi».

Оба скрипта — чистый Python 3 без зависимостей, запускаются на локальной машине.

---

## 9. Что ещё можно

- **Несколько серверов + failover** — 2–3 VPS у разных хостеров, все узлы в одной подписке; при блокировке IP переключаешься в приложении. Резидентная устойчивость.
- **Второй независимый DoH** в клиенте — резерв, если основной DoH недоступен (не оставляй fallback на `system` — утечка в DNS провайдера).
- **XHTTP-транспорт** вторым профилем — против поведенческого анализа ТСПУ (2026). Сложнее: нужен nginx-SNI перед xray либо отдельный порт, и тест на устройстве. Текущий TCP+Reality+Vision оставляй как основной.
- **swap** на 1 GB-ноде — страховка от OOM: `fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` + строка в `/etc/fstab`.

Каждое — независимо. Бери то, что нужно.
