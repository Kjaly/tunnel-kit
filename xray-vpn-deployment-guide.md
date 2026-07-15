# Развёртывание VPN-сервера на Xray Core в Timeweb Cloud

> ⚠️ **Это generic-инструкция по развёртыванию с нуля.** Актуальное боевое состояние (какие серверы работают сейчас, их ключи, логика маршрутизации, что уже настроено) — в [vpn-credentials.md](vpn-credentials.md).
>
> **Важно (2026-07):** для ChatGPT/Google хостер должен быть с нероссийским ASN. Timeweb (AS210976) даёт `unsupported_country` даже при амстердамской локации, т.к. его IP помечен как RU в геобазе OpenAI. Основной рабочий сервер сейчас — DigitalOcean Amsterdam. Подробности и причина — в [vpn-credentials.md](vpn-credentials.md).
>
> **Две модели доступа — не смешивай.** Этот гайд ведёт к строгому варианту: отдельный пользователь `vpnuser`, SSH-порт `2222`, root-вход запрещён. Автоматический сценарий ([ai-setup-prompt.md](ai-setup-prompt.md)) работает проще — `root` по ключу на порту `22`. Выбери ОДИН путь. Если запускал агента из промпта, НЕ применяй потом cloud-init/хардненинг из этого гайда поверх — иначе рискуешь потерять SSH-доступ.

## Содержание

1. [Выбор образа ОС](#1-выбор-образа-ос)
2. [Создание VPS](#2-создание-vps)
3. [Базовая настройка сервера](#3-базовая-настройка-сервера)
4. [Установка и настройка Xray](#4-установка-и-настройка-xray)
5. [Реализация схем маскировки](#5-реализация-схем-маскировки)
6. [Генерация конфигураций клиентов](#6-генерация-конфигураций-клиентов)
7. [Масштабирование](#7-масштабирование)
8. [Мониторинг и обслуживание](#8-мониторинг-и-обслуживание)
9. [Типовые ошибки и решение](#9-типовые-ошибки-и-решение)
10. [Чек-лист после установки](#10-чек-лист-после-установки)
11. [Быстрые команды для диагностики](#11-быстрые-команды-для-диагностики)
12. [Cloud-init скрипт](#12-cloud-init-скрипт)

---

## 1. Выбор образа ОС

### Ubuntu 24.04 LTS (рекомендуется)

**Почему именно он:**
- Ядро Linux 6.8+ с нативной поддержкой BBRv3 (критично для обхода троттлинга)
- Свежие версии OpenSSL 3.x (TLS 1.3 из коробки)
- Долгосрочная поддержка до 2029 года
- Минимальная задержка в патчах безопасности

**Альтернатива — Ubuntu 22.04 LTS:**
- Используй, если нужна максимальная стабильность
- Ядро 5.15, BBRv1 (хуже противостоит packet shaping)
- Поддержка до 2027 года

**Требования к серверу:**

| Параметр | Минимум | Рекомендуется |
|----------|---------|---------------|
| CPU | 1 vCore | 2 vCore |
| RAM | 512 MB | 1 GB |
| Disk | 10 GB SSD | 20 GB SSD |
| Network | 100 Mbps | 200+ Mbps |

**Почему это важно:**
- 1 vCore не справится с шифрованием при >50 Mbps на 3+ подключениях
- <512 MB RAM приведёт к OOM при обновлениях системы

---

## 2. Создание VPS

> ⚠️ Ниже примеры показаны на Timeweb Cloud, но **для ChatGPT/Google выбирай НЕ-российского хостера** (DigitalOcean, Vultr, Contabo, OVH). Timeweb (AS210976) даёт `unsupported_country` для AI-сервисов — используй его только если AI не нужен. Шаги настройки идентичны для любого хостера.

### 2.1. Параметры инстанса

```
Регион: Амстердам (AMS) или Франкфурт (FRA)
    ↳ Москва: ×10 вероятность попасть под блокировку по IP-подсети
    ↳ Европа: лучшие маршруты в РФ через IX (MSK-IX, DataIX)

Конфигурация:
- ОС: Ubuntu 24.04 LTS
- Тариф: Cloud 1 (1 vCore, 1 GB RAM, 15 GB SSD)
- IP: выделенный IPv4 (обязательно) — 180₽/мес
- IPv6: включить (если доступно) — бесплатно
```

### 2.2. SSH-доступ (на этапе создания)

**Генерация SSH-ключа на локальной машине:**

```bash
# Создаём ED25519-ключ (быстрее RSA)
ssh-keygen -t ed25519 -C "my-vps" -f ~/.ssh/xray_key

# Выводим публичную часть
cat ~/.ssh/xray_key.pub
```

**В панели Timeweb:**
1. Вставь содержимое `~/.ssh/xray_key.pub` в поле SSH-ключа
2. Отключи вход по паролю (критично!)
3. Запиши IP-адрес сервера → `YOUR_SERVER_IP`

### 2.3. Firewall (первый запуск)

**В панели Timeweb Cloud:**

```
Правила входящих соединений:
1. SSH (22/tcp) — твой IP (найди на https://ifconfig.me)
2. HTTP (80/tcp) — 0.0.0.0/0 (для Let's Encrypt)
3. HTTPS (443/tcp) — 0.0.0.0/0 (основной порт VPN)

Правила исходящих:
- Разрешить все
```

**Что будет, если пропустить:**
- Открытый SSH на 0.0.0.0/0 → 10k+ попыток брутфорса в сутки
- Закрытый 80/tcp → не получим SSL-сертификат

---

## 3. Базовая настройка сервера

### 3.1. Первое подключение

```bash
# Подключаемся
ssh -i ~/.ssh/xray_key root@YOUR_SERVER_IP

# Создаём alias для удобства
echo "alias vpn='ssh -i ~/.ssh/xray_key root@YOUR_SERVER_IP'" >> ~/.bashrc
source ~/.bashrc
```

### 3.2. Обновление системы

```bash
# Обновляем индекс пакетов
apt update

# Обновляем все пакеты (займёт 2-3 минуты)
apt upgrade -y

# Устанавливаем базовые утилиты
apt install -y curl wget nano ufw fail2ban unattended-upgrades htop vnstat qrencode python3 jq bc

# Включаем автообновления безопасности
dpkg-reconfigure -plow unattended-upgrades
```

**Почему это важно:**
- Без обновлений уязвимости типа Dirty COW эксплуатируются за <24 часа

### 3.3. Создание пользователя без root

```bash
# Создаём пользователя
adduser vpnuser --disabled-password --gecos ""

# Добавляем в sudo
usermod -aG sudo vpnuser

# Копируем SSH-ключи
mkdir -p /home/vpnuser/.ssh
cp /root/.ssh/authorized_keys /home/vpnuser/.ssh/
chown -R vpnuser:vpnuser /home/vpnuser/.ssh
chmod 700 /home/vpnuser/.ssh
chmod 600 /home/vpnuser/.ssh/authorized_keys

# Проверяем подключение (НЕ ЗАКРЫВАЙ текущую сессию!)
# В новом терминале:
ssh -i ~/.ssh/xray_key vpnuser@YOUR_SERVER_IP
```

### 3.4. SSH Hardening

```bash
# Редактируем конфиг
nano /etc/ssh/sshd_config
```

**Изменения:**

```nginx
# Отключаем root-вход
PermitRootLogin no

# Только ключи, без паролей
PasswordAuthentication no
PubkeyAuthentication yes

# Отключаем пустые пароли
PermitEmptyPasswords no

# Меняем порт (опционально, усложняет сканирование)
Port 2222

# Только конкретный пользователь
AllowUsers vpnuser

# Протокол 2 (старый убираем)
Protocol 2

# Ограничение попыток аутентификации
MaxAuthTries 3
MaxSessions 2
```

```bash
# Применяем
systemctl restart sshd

# Проверяем статус
systemctl status sshd
```

**Что будет, если пропустить:**
- PermitRootLogin yes → прямой доступ к root при компрометации ключа
- Port 22 → 95% ботов сканируют именно его

### 3.5. Fail2Ban

```bash
# Устанавливаем
apt install -y fail2ban

# Создаём локальный конфиг
nano /etc/fail2ban/jail.local
```

```ini
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
destemail = твой_email@example.com
sendername = Fail2Ban
action = %(action_mwl)s

[sshd]
enabled = true
port = 2222
logpath = /var/log/auth.log
```

```bash
# Запускаем
systemctl enable fail2ban
systemctl start fail2ban

# Проверяем
fail2ban-client status sshd
```

### 3.6. Firewall (UFW)

```bash
# Сбрасываем правила
ufw --force reset

# Дефолтные политики
ufw default deny incoming
ufw default allow outgoing

# Разрешаем SSH (используй свой порт!)
ufw allow 2222/tcp comment 'SSH'

# Разрешаем HTTP/HTTPS
ufw allow 80/tcp comment 'HTTP для certbot'
ufw allow 443/tcp comment 'HTTPS/Xray'

# Включаем (подтверди Yes)
ufw enable

# Проверяем
ufw status verbose
```

**Почему это важно:**
- Без firewall открыты все порты → сканеры найдут уязвимые сервисы за минуты

### 3.7. Timezone и Locale

```bash
# Устанавливаем часовой пояс Москвы
timedatectl set-timezone Europe/Moscow

# Проверяем
timedatectl

# Настраиваем локаль
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

# Перелогиниваемся
exit
ssh -i ~/.ssh/xray_key vpnuser@YOUR_SERVER_IP
```

---

## 4. Установка и настройка Xray

### 4.1. Что такое Xray

**Xray Core** — форк V2Ray с фокусом на:
- Производительность (на 30-40% быстрее V2Ray)
- Новые протоколы (VLESS, XTLS-Vision, Reality)
- Активная разработка (V2Ray практически заморожен)

**Ключевое отличие:**
- V2Ray: VMess + устаревший TLS 1.2 → легко детектируется
- Xray: VLESS + Reality → трафик неотличим от обычного HTTPS

### 4.2. Установка Xray

```bash
# Скачиваем официальный скрипт установки
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Проверяем версию
xray version
```

**Вывод должен быть:**
```
Xray 1.8.x (Xray, Penetrates Everything.) Custom (go1.21.x linux/amd64)
```

```bash
# Структура установки:
# /usr/local/bin/xray — бинарник
# /usr/local/etc/xray/ — конфиги
# /usr/local/share/xray/ — geoip/geosite
# /var/log/xray/ — логи

# Создаём директорию для конфигов
mkdir -p /usr/local/etc/xray
```

### 4.3. Генерация UUID и ключей

```bash
# UUID для пользователя (запиши!)
xray uuid

# Пример вывода:
# f8e7d9c2-1a3b-4f5e-8d7c-9b2a1e3f4d5c

# Сохраняем в переменную (используй свой!)
export USER_UUID="f8e7d9c2-1a3b-4f5e-8d7c-9b2a1e3f4d5c"

# Генерируем ключи для Reality (запиши оба!)
xray x25519

# Вывод:
# Private key: SLdQKqKW_your_private_key_here
# Public key: z8mFQx_your_public_key_here

export PRIVATE_KEY="SLdQKqKW_your_private_key_here"
export PUBLIC_KEY="z8mFQx_your_public_key_here"
```

---

## 5. Реализация схем маскировки

### 5.1. VLESS + Reality (основная схема)

**Что это:**
- Клиент подключается к "фейковому" TLS-серверу (например, discord.com)
- Xray распознаёт трафик по специальному заголовку
- DPI видит легальный HTTPS-трафик

**Почему лучше:**
- Нет собственного сертификата → не детектируется по отпечатку
- Трафик идентичен реальному сайту

#### 5.1.1. Выбор домена для маскировки

```bash
# Критерии:
# 1. Популярный CDN (Cloudflare, Fastly)
# 2. TLS 1.3
# 3. Не блокируется в РФ

# Проверяем кандидатов:
echo | openssl s_client -connect discord.com:443 -servername discord.com 2>/dev/null | grep "Protocol"

# Хорошие варианты:
# - www.speedtest.net (Ookla, Cloudflare)
# - discord.com (Cloudflare)
# - www.logitech.com (Akamai)

# Плохие:
# - google.com (слишком известен для обфускации)
# - любые .ru домены

export DEST_DOMAIN="www.speedtest.net"
export DEST_SERVER="104.18.24.167"  # IP speedtest.net
```

#### 5.1.2. Конфигурация Xray

```bash
nano /usr/local/etc/xray/config.json
```

```json
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "f8e7d9c2-1a3b-4f5e-8d7c-9b2a1e3f4d5c",
            "flow": "xtls-rprx-vision",
            "email": "vpnuser@xray"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.speedtest.net:443",
          "xver": 0,
          "serverNames": [
            "www.speedtest.net"
          ],
          "privateKey": "SLdQKqKW_your_private_key_here",
          "shortIds": [
            "REPLACE_ME_openssl_rand_hex_8"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
```

**Объяснение параметров:**

```yaml
port: 443 — стандартный HTTPS, не вызывает подозрений
flow: xtls-rprx-vision — ускорение за счёт сплайсинга TCP
dest: www.speedtest.net:443 — куда идёт "левый" трафик
serverNames — список доменов, которые клиент может указывать
privateKey — из xray x25519
shortIds — обфускация; ГЕНЕРИРУЙ случайно (openssl rand -hex 8), НЕ копируй литерал и НЕ оставляй пустую строку (пустой sid пускает клиентов без идентификатора — слабее)
sniffing — определение протокола по содержимому (для обхода DNS-блокировок)
geoip:private — блокируем локальные адреса (защита от утечек)
bittorrent — блокируем торренты (опционально)
```

```bash
# Запускаем Xray
systemctl enable xray
systemctl start xray

# Проверяем
systemctl status xray

# Должен быть статус: active (running)

# Смотрим логи
tail -f /var/log/xray/error.log
```

**Что будет, если пропустить:**
- Неправильный `dest` → клиент не подключится (timeout)
- Несоответствие `privateKey` → клиент увидит "bad key"

### 5.2. VLESS + TLS + WebSocket (резервная схема)

**Когда использовать:**
- Reality не работает из-за фильтрации по SNI
- Нужна совместимость со старыми клиентами

**Недостатки:**
- Нужен собственный домен
- Детектируется по сертификату

#### 5.2.1. Покупка домена

```
Регистратор: Namecheap, Porkbun, Google Domains
Зона: .com, .net, .org (НЕ .ru, .рф)
Имя: случайное, не связанное с VPN
Пример: digital-portfolio-vpnuser.com

DNS-записи:
A — YOUR_SERVER_IP
AAAA — ваш IPv6 (если есть)
```

#### 5.2.2. Установка Nginx + Certbot

```bash
# Устанавливаем
apt install -y nginx certbot python3-certbot-nginx

# Останавливаем (занимает 80-й порт)
systemctl stop nginx

# Получаем сертификат
certbot certonly --standalone -d digital-portfolio-vpnuser.com --agree-tos -m твой_email@example.com

# Сертификаты здесь:
# /etc/letsencrypt/live/digital-portfolio-vpnuser.com/fullchain.pem
# /etc/letsencrypt/live/digital-portfolio-vpnuser.com/privkey.pem

# Автообновление
systemctl enable certbot.timer
```

#### 5.2.3. Конфигурация Nginx (fallback)

```bash
nano /etc/nginx/sites-available/xray-fallback
```

```nginx
server {
    listen 80;
    server_name digital-portfolio-vpnuser.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name digital-portfolio-vpnuser.com;

    ssl_certificate /etc/letsencrypt/live/digital-portfolio-vpnuser.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/digital-portfolio-vpnuser.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    # WebSocket для Xray
    location /xray-ws {
        if ($http_upgrade != "websocket") {
            return 404;
        }
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }
}
```

```bash
# Создаём простую заглушку
cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head><title>Portfolio</title></head>
<body><h1>Under construction</h1></body>
</html>
EOF

# Активируем конфиг
ln -s /etc/nginx/sites-available/xray-fallback /etc/nginx/sites-enabled/
rm /etc/nginx/sites-enabled/default

# Проверяем синтаксис
nginx -t

# Запускаем
systemctl restart nginx
systemctl enable nginx
```

#### 5.2.4. Xray конфигурация (WebSocket)

```bash
nano /usr/local/etc/xray/config-ws.json
```

```json
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "f8e7d9c2-1a3b-4f5e-8d7c-9b2a1e3f4d5c",
            "email": "vpnuser@xray-ws"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/xray-ws"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
```

```bash
# Создаём отдельный systemd-unit (для переключения схем)
cat > /etc/systemd/system/xray-ws.service <<EOF
[Unit]
Description=Xray WebSocket Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config-ws.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Перезагружаем systemd
systemctl daemon-reload
```

**Переключение схем:**

```bash
# Reality (основная)
systemctl stop xray-ws
systemctl start xray

# WebSocket (резервная)
systemctl stop xray
systemctl start xray-ws
```

---

## 6. Генерация конфигураций клиентов

### 6.1. Reality-конфиг (универсальный JSON)

```bash
# Создаём конфиг клиента
cat > ~/client-reality-vpnuser.json <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "YOUR_SERVER_IP",
        "port": 443,
        "users": [
          {
            "id": "f8e7d9c2-1a3b-4f5e-8d7c-9b2a1e3f4d5c",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "www.speedtest.net",
      "fingerprint": "chrome",
      "show": false,
      "publicKey": "z8mFQx_your_public_key_here",
      "shortId": "REPLACE_ME_openssl_rand_hex_8",
      "spiderX": ""
    }
  }
}
EOF
```

### 6.2. Конвертация в share-ссылки

```bash
# Для Reality ссылка сложная, используем Python-скрипт
cat > ~/generate_vless_link.py <<'EOF'
import json
import base64
import urllib.parse

with open('client-reality-vpnuser.json', 'r') as f:
    config = json.load(f)

vnext = config['settings']['vnext'][0]
user = vnext['users'][0]
reality = config['streamSettings']['realitySettings']

# Формат: vless://UUID@HOST:PORT?params#NAME
uuid = user['id']
address = vnext['address']
port = vnext['port']

params = {
    'security': 'reality',
    'encryption': 'none',
    'pbk': reality['publicKey'],
    'fp': reality['fingerprint'],
    'sni': reality['serverName'],
    'sid': reality['shortId'],
    'type': 'tcp',
    'flow': user['flow']
}

params_str = '&'.join([f"{k}={urllib.parse.quote(v)}" for k, v in params.items()])
link = f"vless://{uuid}@{address}:{port}?{params_str}#Anton-Reality-VPN"

print(link)
EOF

# Запускаем
python3 ~/generate_vless_link.py

# Копируем вывод (это ссылка для клиентов)
```

### 6.3. QR-код (для мобильных)

```bash
# Устанавливаем генератор QR
apt install -y qrencode

# Генерируем QR-код в терминале
python3 ~/generate_vless_link.py | qrencode -t ANSIUTF8

# Или сохраняем в PNG
python3 ~/generate_vless_link.py | qrencode -o ~/xray-qr.png

# Скачиваем на локальную машину
# (на локальной машине)
scp -i ~/.ssh/xray_key vpnuser@YOUR_SERVER_IP:~/xray-qr.png ~/Downloads/
```

### 6.4. Инструкции по клиентам

#### Android

```
Клиент: v2rayNG
Ссылка: https://github.com/2dust/v2rayNG/releases

1. Устанавливаем APK
2. Нажимаем "+" → "Импорт из буфера обмена"
3. Вставляем ссылку vless://... или сканируем QR
4. Сохраняем
5. Подключаемся (кнопка внизу)

Проверка: открываем https://ifconfig.me — должен быть IP сервера
```

#### iOS

```
Клиент: Shadowrocket (платный, $2.99) или Streisand (бесплатный)
Ссылка: App Store

Shadowrocket:
1. Открываем приложение
2. Нажимаем "+" → "Type: VLESS"
3. Вручную вводим:
   - Address: YOUR_SERVER_IP
   - Port: 443
   - UUID: f8e7d9c2-1a3b-4f5e-8d7c-9b2a1e3f4d5c
   - TLS: включить
   - Server Name: www.speedtest.net
   - Reality: включить
   - Public Key: z8mFQx_your_public_key_here
4. Сохраняем и подключаемся

Streisand:
1. Импортируем через QR-код
2. Подключаемся
```

#### macOS

```
Клиент: V2RayXS
Ссылка: https://github.com/tzmax/V2RayXS/releases

1. Скачиваем .dmg
2. Устанавливаем
3. Запускаем V2RayXS
4. Нажимаем "Import from clipboard"
5. Вставляем ссылку
6. Enable (галочка в меню)

Проверка: curl ifconfig.me
```

#### Windows

```
Клиент: v2rayN
Ссылка: https://github.com/2dust/v2rayN/releases

1. Скачиваем v2rayN-With-Core.zip
2. Распаковываем
3. Запускаем v2rayN.exe
4. Правой кнопкой на иконку в трее → "Добавить сервер из буфера"
5. Вставляем ссылку
6. Правой кнопкой → "Установить как активный сервер"
7. Включаем прокси (System Proxy: Enable)

Проверка: открываем ifconfig.me в браузере
```

#### Linux (GUI)

```
Клиент: Qv2ray + Xray-core
Установка (Ubuntu/Debian):

# Скачиваем Xray-core
wget https://github.com/XTLS/Xray-core/releases/download/v1.8.x/Xray-linux-64.zip
unzip Xray-linux-64.zip -d ~/.config/qv2ray/

# Скачиваем Qv2ray
wget https://github.com/Qv2ray/Qv2ray/releases/download/v2.7.0/Qv2ray-v2.7.0-linux-x64.AppImage
chmod +x Qv2ray-v2.7.0-linux-x64.AppImage

# Запускаем
./Qv2ray-v2.7.0-linux-x64.AppImage

# В настройках указываем путь к Xray-core
# Импортируем конфиг через JSON
```

#### Linux (CLI через systemd)

```bash
# Копируем конфиг на клиентскую машину
scp -i ~/.ssh/xray_key vpnuser@YOUR_SERVER_IP:~/client-reality-vpnuser.json ~/

# Устанавливаем Xray локально
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Создаём клиентский конфиг
sudo nano /usr/local/etc/xray/client-config.json
```

```json
{
  "inbounds": [
    {
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    },
    {
      "port": 10809,
      "listen": "127.0.0.1",
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "YOUR_SERVER_IP",
            "port": 443,
            "users": [
              {
                "id": "f8e7d9c2-1a3b-4f5e-8d7c-9b2a1e3f4d5c",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "www.speedtest.net",
          "fingerprint": "chrome",
          "show": false,
          "publicKey": "z8mFQx_your_public_key_here",
          "shortId": "REPLACE_ME_openssl_rand_hex_8"
        }
      }
    }
  ]
}
```

```bash
# Создаём systemd-unit
sudo cat > /etc/systemd/system/xray-client.service <<EOF
[Unit]
Description=Xray Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/client-config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Запускаем
sudo systemctl daemon-reload
sudo systemctl enable xray-client
sudo systemctl start xray-client

# Проверяем
curl --socks5 127.0.0.1:10808 ifconfig.me

# Для использования во всей системе:
export http_proxy=http://127.0.0.1:10809
export https_proxy=http://127.0.0.1:10809

# Или настраиваем через ProxyChains
sudo apt install -y proxychains4
sudo nano /etc/proxychains4.conf
# Добавляем в конец:
# socks5 127.0.0.1 10808
```

---

## 7. Масштабирование

### 7.1. Добавление пользователей

```bash
# Генерируем новый UUID
xray uuid
# Пример: a1b2c3d4-e5f6-7890-abcd-ef1234567890

# Редактируем конфиг
nano /usr/local/etc/xray/config.json

# В секцию "clients" добавляем:
```

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "flow": "xtls-rprx-vision",
  "email": "user2@xray"
}
```

```bash
# Перезапускаем
systemctl restart xray

# Генерируем ссылку для нового пользователя (меняем UUID в скрипте)
```

### 7.2. Ограничения по трафику

**Xray не имеет встроенных лимитов, используем iptables:**

```bash
# Устанавливаем счётчик трафика
apt install -y vnstat

# Инициализируем интерфейс
vnstat -i eth0

# Смотрим статистику
vnstat -d

# Для лимитов используем скрипт:
cat > /usr/local/bin/traffic-limit.sh <<'EOF'
#!/bin/bash
# Лимит 100 GB/месяц на пользователя

USER_IP="CLIENT_IP_HERE"
LIMIT_GB=100
CURRENT_GB=$(vnstat -i eth0 --json | jq '.interfaces[0].traffic.month[0].tx' | awk '{print $1/1024/1024/1024}')

if (( $(echo "$CURRENT_GB > $LIMIT_GB" | bc -l) )); then
    iptables -I FORWARD -s $USER_IP -j DROP
    echo "User $USER_IP exceeded limit"
fi
EOF

chmod +x /usr/local/bin/traffic-limit.sh

# Запускаем через cron (ежедневно)
echo "0 2 * * * /usr/local/bin/traffic-limit.sh" | crontab -
```

### 7.3. Ротация ключей (безопасность)

```bash
# Генерируем новую пару
xray x25519

# Обновляем config.json (privateKey)
nano /usr/local/etc/xray/config.json

# Перезапускаем
systemctl restart xray

# Обновляем все клиентские конфиги (publicKey)
# Отправляем новые ссылки пользователям
```

**Почему это важно:**
- Компрометация ключа → доступ для третьих лиц
- Рекомендуется ротация раз в 3-6 месяцев

---

## 8. Мониторинг и обслуживание

### 8.1. Systemd (автозапуск)

```bash
# Проверяем статус
systemctl status xray

# Логи с момента загрузки
journalctl -u xray -b

# Логи в реальном времени
journalctl -u xray -f

# Перезапуск при сбое (уже настроено в unit-файле)
# Restart=on-failure
```

### 8.2. Логирование

```bash
# Создаём logrotate
nano /etc/logrotate.d/xray
```

```
/var/log/xray/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl reload xray > /dev/null 2>&1 || true
    endscript
}
```

```bash
# Тестируем
logrotate -f /etc/logrotate.d/xray

# Анализ логов (топ IP по подключениям)
awk '/accepted/ {print $NF}' /var/log/xray/access.log | sort | uniq -c | sort -rn | head -10
```

### 8.3. Health-check

```bash
# Создаём скрипт проверки
cat > /usr/local/bin/xray-healthcheck.sh <<'EOF'
#!/bin/bash

if ! systemctl is-active --quiet xray; then
    echo "Xray is down, restarting..."
    systemctl restart xray
    echo "Xray restarted at $(date)" >> /var/log/xray-restarts.log
fi

# Проверяем порт 443
if ! nc -z localhost 443; then
    echo "Port 443 not listening, restarting Xray"
    systemctl restart xray
fi
EOF

chmod +x /usr/local/bin/xray-healthcheck.sh

# Добавляем в cron (каждые 5 минут)
echo "*/5 * * * * /usr/local/bin/xray-healthcheck.sh" | crontab -
```

### 8.4. Обновления Xray

```bash
# Проверяем текущую версию
xray version

# Обновляем через скрипт
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Перезапускаем
systemctl restart xray

# Проверяем работу
systemctl status xray
tail -f /var/log/xray/error.log
```

**Подписываемся на обновления:**
- GitHub: https://github.com/XTLS/Xray-core/releases
- Telegram: @ProjectXray

### 8.5. Резервное копирование

```bash
# Создаём скрипт бэкапа
cat > /usr/local/bin/xray-backup.sh <<'EOF'
#!/bin/bash
BACKUP_DIR="/root/xray-backups"
DATE=$(date +%Y%m%d-%H%M%S)

mkdir -p $BACKUP_DIR

# Бэкапим конфиги
tar -czf $BACKUP_DIR/xray-config-$DATE.tar.gz \
    /usr/local/etc/xray/ \
    /etc/nginx/sites-available/xray-fallback \
    /etc/letsencrypt/

# Удаляем старые (>30 дней)
find $BACKUP_DIR -name "*.tar.gz" -mtime +30 -delete

echo "Backup created: xray-config-$DATE.tar.gz"
EOF

chmod +x /usr/local/bin/xray-backup.sh

# Запускаем еженедельно (воскресенье 3:00)
echo "0 3 * * 0 /usr/local/bin/xray-backup.sh" | crontab -

# Скачиваем на локальную машину
scp -i ~/.ssh/xray_key vpnuser@YOUR_SERVER_IP:/root/xray-backups/xray-config-*.tar.gz ~/backups/
```

### 8.6. Мониторинг производительности

```bash
# Устанавливаем vnstat + htop
apt install -y vnstat htop nethogs

# Статистика по трафику
vnstat -l  # Live

# Топ процессов по CPU/RAM
htop

# Топ по сетевому трафику
nethogs eth0

# Быстрая проверка нагрузки
cat <<'EOF' > ~/check.sh
#!/bin/bash
echo "=== Load Average ==="
uptime
echo ""
echo "=== Memory ==="
free -h
echo ""
echo "=== Disk ==="
df -h /
echo ""
echo "=== Xray Status ==="
systemctl status xray | grep Active
echo ""
echo "=== Network Traffic (today) ==="
vnstat -d | grep today
EOF
chmod +x ~/check.sh
```

---

## 9. Типовые ошибки и решение

### 9.1. Клиент не подключается (Connection Timeout)

**Симптомы:**
- Android: "Connection timeout"
- iOS: "Unable to connect"
- Логи сервера: пусто

**Диагностика:**

```bash
# 1. Проверяем, что Xray запущен
systemctl status xray

# 2. Проверяем порт 443
ss -tulpn | grep 443

# 3. Проверяем firewall
ufw status

# 4. Пингуем сервер с клиента
ping YOUR_SERVER_IP

# 5. Проверяем доступность порта извне
# (на локальной машине)
nc -zv YOUR_SERVER_IP 443
```

**Решение:**

```bash
# Если порт не открыт:
ufw allow 443/tcp
systemctl restart xray

# Если Xray не запущен:
systemctl start xray
journalctl -u xray -n 50

# Проверяем конфиг на ошибки:
xray run -test -config /usr/local/etc/xray/config.json
```

### 9.2. Обрывы соединения каждые 2-3 минуты

**Симптомы:**
- Подключение устанавливается, но через 2-3 минуты рвётся
- Браузер показывает "ERR_CONNECTION_RESET"

**Причина:** TCP keep-alive или timeout

**Решение:**

```bash
# Редактируем конфиг Xray
nano /usr/local/etc/xray/config.json

# Добавляем в inbound:
```

```json
"streamSettings": {
  "network": "tcp",
  "tcpSettings": {
    "header": {
      "type": "none"
    }
  },
  "sockopt": {
    "tcpKeepAliveInterval": 30,
    "tcpKeepAliveIdle": 300
  }
}
```

```bash
# Перезапускаем
systemctl restart xray
```

### 9.3. Низкая скорость (< 10 Mbps)

**Симптомы:**
- Speedtest показывает 5-10 Mbps при канале 100 Mbps
- YouTube грузится медленно

**Диагностика:**

```bash
# 1. Проверяем загрузку CPU
htop

# 2. Проверяем MTU
ip link show eth0 | grep mtu

# 3. Тестируем скорость напрямую (без VPN)
curl -o /dev/null http://speedtest.tele2.net/100MB.zip
```

**Решение:**

```bash
# Включаем BBR (TCP Congestion Control)
cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
EOF

sysctl -p

# Проверяем BBR
sysctl net.ipv4.tcp_congestion_control
# Должно быть: net.ipv4.tcp_congestion_control = bbr

# Оптимизируем MTU (если < 1500)
ip link set dev eth0 mtu 1500

# В конфиге Xray меняем flow на xtls-rprx-vision (уже есть)
# Это даёт +30-50% к скорости
```

### 9.4. Блокировка по IP

**Симптомы:**
- Работало, потом резко перестало
- Другие серверы работают
- Логи: "connection reset by peer"

**Диагностика:**

```bash
# Проверяем, доступен ли сервер из других стран
# (используем VPN-сервис или proxy-checker)
curl -x socks5://ДРУГОЙ_VPN https://YOUR_SERVER_IP

# Проверяем IP в blacklist
# https://www.abuseipdb.com/check/YOUR_SERVER_IP
```

**Решение:**

```bash
# 1. Меняем IP-адрес (через панель Timeweb Cloud)
# Или
# 2. Используем CDN (Cloudflare) + WebSocket

# Настройка через Cloudflare:
# - Заводим домен на Cloudflare
# - Включаем Proxy (оранжевая иконка)
# - В Xray меняем порт на 80 или 8080
# - В клиентах указываем домен вместо IP
```

### 9.5. "Bad key" или "Invalid configuration"

**Симптомы:**
- Клиент пишет "bad key"
- "Invalid VLESS configuration"

**Причина:** Несоответствие приватного/публичного ключа

**Решение:**

```bash
# Генерируем новую пару
xray x25519

# Копируем:
# Private key: ... → в config.json на сервере (privateKey)
# Public key: ... → в клиентские конфиги (publicKey)

# Проверяем, что UUID совпадает
grep '"id"' /usr/local/etc/xray/config.json

# Перезапускаем
systemctl restart xray

# Пересоздаём клиентские ссылки
python3 ~/generate_vless_link.py
```

### 9.6. "Destination unreachable" для некоторых сайтов

**Симптомы:**
- YouTube работает
- Некоторые сайты не открываются (особенно российские)

**Причина:** DNS-блокировки или routing

**Решение:**

```bash
# Проверяем DNS
dig google.com

# Меняем DNS на сервере
nano /etc/systemd/resolved.conf

# Раскомментируем и меняем:
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9

systemctl restart systemd-resolved

# В конфиге Xray включаем sniffing (уже есть)
# Это обходит DNS-блокировки через определение протокола

# Для клиентов: в настройках приложения включить
# "Route all traffic" или "Global mode"
```

### 9.7. Высокое потребление CPU (>80%)

**Симптомы:**
- htop показывает xray жрёт 80-100% CPU
- Сервер тормозит

**Причина:** Атака (port scan) или багный клиент

**Диагностика:**

```bash
# Смотрим активные подключения
netstat -tn | grep :443 | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn

# Если один IP > 100 подключений → атака
```

**Решение:**

```bash
# Банним IP через iptables
iptables -I INPUT -s АТАКУЮЩИЙ_IP -j DROP

# Включаем rate-limiting в firewall
ufw limit 443/tcp

# Или через iptables:
iptables -A INPUT -p tcp --dport 443 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 443 -m state --state NEW -m recent --update --seconds 60 --hitcount 20 -j DROP

# Сохраняем правила
iptables-save > /etc/iptables/rules.v4
```

### 9.8. "Certificate error" (для WebSocket-схемы)

**Симптомы:**
- SSL certificate expired
- Untrusted certificate

**Решение:**

```bash
# Обновляем сертификат
certbot renew --force-renewal

# Проверяем автообновление
systemctl status certbot.timer

# Если не активен:
systemctl enable certbot.timer
systemctl start certbot.timer

# Проверяем срок сертификата
openssl x509 -in /etc/letsencrypt/live/digital-portfolio-vpnuser.com/fullchain.pem -noout -dates

# Должен быть валиден ещё 60+ дней
```

---

## 10. Чек-лист после установки

```
✅ Сервер обновлён (apt update && apt upgrade)
✅ SSH работает только по ключу (PasswordAuthentication no)
✅ Пользователь без root создан (vpnuser)
✅ Fail2Ban активен (systemctl status fail2ban)
✅ UFW включён (ufw status)
✅ Xray запущен (systemctl status xray)
✅ Порт 443 открыт (nc -zv YOUR_SERVER_IP 443)
✅ Логи пишутся (/var/log/xray/error.log)
✅ Клиент подключается (проверка на телефоне)
✅ Скорость > 50 Mbps (speedtest через VPN)
✅ IP сменился (curl ifconfig.me через VPN)
✅ DNS работает (ping google.com через VPN)
✅ Бэкап настроен (crontab -l | grep backup)
✅ Мониторинг активен (crontab -l | grep healthcheck)
```

---

## 11. Быстрые команды для диагностики

```bash
# Сохраняем как алиасы в ~/.bashrc
cat >> ~/.bashrc <<'EOF'
alias xray-status='systemctl status xray'
alias xray-restart='systemctl restart xray && journalctl -u xray -f'
alias xray-logs='tail -f /var/log/xray/error.log'
alias xray-connections='netstat -tn | grep :443'
alias xray-traffic='vnstat -l'
alias xray-check='curl -so /dev/null -w "%{http_code}" https://YOUR_SERVER_IP && echo " OK" || echo " FAIL"'
EOF

source ~/.bashrc
```

---

## 12. Cloud-init скрипт

**Для автоматизации начальной настройки при создании VPS:**

```bash
#!/bin/bash

# Обновление системы
apt-get update
apt-get upgrade -y

# Установка базовых пакетов
apt-get install -y curl wget nano ufw fail2ban unattended-upgrades htop vnstat qrencode python3 jq bc netcat-openbsd

# Включение автообновлений безопасности
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades

# Создание пользователя vpnuser
useradd -m -s /bin/bash vpnuser
usermod -aG sudo vpnuser
echo "vpnuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/vpnuser

# Копирование SSH-ключей для vpnuser
mkdir -p /home/vpnuser/.ssh
cp -r /root/.ssh/authorized_keys /home/vpnuser/.ssh/
chown -R vpnuser:vpnuser /home/vpnuser/.ssh
chmod 700 /home/vpnuser/.ssh
chmod 600 /home/vpnuser/.ssh/authorized_keys

# SSH Hardening
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
echo "AllowUsers vpnuser" >> /etc/ssh/sshd_config
systemctl restart sshd

# Настройка Fail2Ban
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = 22
logpath = /var/log/auth.log
EOF
systemctl enable fail2ban
systemctl start fail2ban

# Настройка UFW
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# Timezone и Locale
timedatectl set-timezone Europe/Moscow
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

# BBR для производительности
cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
EOF
sysctl -p

# Создание директорий для логов
mkdir -p /var/log/xray
chmod 755 /var/log/xray

# Сообщение о завершении
echo "Cloud-init завершён. Подключайся через: ssh vpnuser@IP" > /root/cloud-init-done.txt
echo "Следующий шаг: установка Xray вручную" >> /root/cloud-init-done.txt

# Перезагрузка для применения всех изменений
reboot
```

**Как использовать Cloud-init:**

1. Скопируй скрипт в поле Cloud-init при создании VPS
2. Создай сервер
3. Подожди 3-5 минут (сервер перезагрузится автоматически)
4. Подключись: `ssh -i ~/.ssh/xray_key vpnuser@YOUR_SERVER_IP`
5. Продолжи установку с раздела 4 (Установка Xray)

---

## Контакты и поддержка

**Если что-то не работает:**

1. Проверь логи: `journalctl -u xray -n 100`
2. Проверь конфиг: `xray run -test -config /usr/local/etc/xray/config.json`
3. Проверь firewall: `ufw status verbose`
4. Проверь сеть: `nc -zv YOUR_SERVER_IP 443`

**Сообщества:**
- Telegram: @ProjectXray
- GitHub: https://github.com/XTLS/Xray-core/issues
- Reddit: r/VPN

---

## Итог

Ты получил production-ready VPN-сервер, который:

✅ **Устойчив к блокировкам** — Reality маскирует трафик под легитимный HTTPS  
✅ **Быстрый** — BBR + XTLS дают максимальную скорость  
✅ **Безопасный** — SSH по ключам, fail2ban, firewall, регулярные обновления  
✅ **Масштабируемый** — легко добавлять пользователей и ротировать ключи  
✅ **Надёжный** — логи, мониторинг, автоперезапуск, бэкапы  

**Следующие шаги:**
1. Запусти сервер и подключись с телефона
2. Протестируй скорость (speedtest.net)
3. Настрой бэкапы и мониторинг
4. Добавь пользователей (если нужно)

Успехов в обходе блокировок! 🚀
