# Настройка VPN «под ключ» руками ИИ-агента

Отдай этот файл ИИ-агенту, у которого есть **shell и SSH** (Claude Code, Cursor Agent, Aider с bash, любой agentic-CLI). Заполни блок `INPUTS`, вставь промпт — агент сам проверит сервер, поставит и настроит xray, укрепит машину и выдаст готовую vless-ссылку, QR и клиентский конфиг Shadowrocket с раздельным туннелированием.

---

## Часть 1. Что подготовить ДО запуска (5 минут)

1. **Шаг 0 — создай SSH-ключ** (если ещё нет). Это пара «замок+ключ»: публичную часть вставишь при создании сервера, приватную не отдаёшь никому.
   - macOS / Linux — в терминале:
     ```bash
     ssh-keygen -t ed25519 -f ~/.ssh/xray_key      # Enter на всё
     cat ~/.ssh/xray_key.pub                        # это вставишь в поле SSH при создании VPS
     ```
   - Windows — в PowerShell та же команда `ssh-keygen -t ed25519 -f $HOME\.ssh\xray_key` (ssh есть в Windows 10/11 из коробки), паблик: `type $HOME\.ssh\xray_key.pub`.
2. **Создай VPS у не-российского хостера.** Критично: OpenAI/Google банят по ASN, и российский хостер (даже с сервером в ЕС) даёт `unsupported_country`. Универсальные шаги — одинаковы у любого провайдера (DigitalOcean, Vultr, Contabo, OVH; Hetzner требует паспорт):
   1. Зарегистрируйся, привяжи карту (иностранная работает; из РФ — карта другой страны/крипта у части хостеров).
   2. Create Server / Droplet / Instance.
   3. **Регион/локация**: Нидерланды, Германия или Финляндия (низкий пинг из РФ).
   4. **ОС (Image)**: Ubuntu 24.04 LTS.
   5. **Размер**: самый дешёвый Basic/Shared — 1 vCPU / 1 GB / ~25 GB. Оплата почасовая — если IP забанен, пересоздашь и получишь новый.
   6. **Аутентификация → SSH Key**: вставь содержимое `~/.ssh/xray_key.pub` из шага 0 (не «пароль»).
   7. Создай сервер, скопируй его публичный **IPv4** — это `SERVER_IP` для промпта.
   - Проверить «чистоту» IP до настройки агент сделает сам (hard-gate в промпте); если IP грязный — просто удали сервер (Destroy) и создай заново.
3. **SSH-доступ к серверу:**
   - Публичный IP сервера (появится после создания).
   - Приватный ключ `~/.ssh/xray_key` уже у тебя на машине из шага 0. «Дать SSH» = указать в INPUTS IP и путь к ключу; вручную ничего прокидывать не нужно.
   - ⚠️ Агент должен работать **на твоём компьютере**, где лежит `~/.ssh/xray_key` — облачный агент этот ключ не увидит.
4. **Клиент на телефоне/маке:** Shadowrocket (App Store, iOS/macOS $2.99) или бесплатный Streisand.
5. **(Опционально) Рабочий WireGuard-конфиг** — если хочешь, чтобы рабочие/корпоративные IP шли через отдельный туннель. Положи файл рядом и дай агенту путь к нему (НЕ вставляй ключи в тело промпта — см. constraints).

> Ничего ставить локально не нужно — всё делает агент по SSH. От тебя только IP и путь к ключу.

---

## Часть 2. Промпт для агента

Заполни `INPUTS` своими значениями и вставь агенту **целиком**:

````text
<role>
Ты — DevOps-инженер. Настраиваешь личный анти-DPI VPN на свежем VPS по SSH: VLESS + Reality + XTLS-Vision (xray-core). Действуешь автономно, но останавливаешься на явных гейтах ниже.
</role>

<inputs>
# Менять нужно только SERVER_IP и SSH_KEY. Остальные поля уже с рабочими значениями — оставь как есть.
SERVER_IP      = <IP сервера>
SSH_KEY        = <путь к приватному ключу, напр. ~/.ssh/xray_key>
SSH_USER       = root
REALITY_DEST   = www.samsung.com          # проверенный Reality-dest, НЕ Cloudflare (www.microsoft.com НЕ работает!)
NODE_NAME      = MY-VPN                    # имя узла в клиенте (латиница/цифры/дефис)
# --- опционально, для раздельного туннелирования рабочих IP ---
WORK_WG_FILE   = нет                       # или путь к локальному файлу WireGuard (НЕ вставляй ключи сюда)
WORK_IPS       = нет                       # или список IP через запятую -> пойдут через WORK_WG
</inputs>

<hard_gates>
1. ПРОВЕРКА ЧИСТОТЫ IP ДО НАСТРОЙКИ. Зайди по SSH и выполни:
   curl -4 -s https://chatgpt.com/cdn-cgi/trace | grep -E "^(ip|loc)="
   curl -4 -s -o /dev/null -w "aistudio:%{http_code}\n" -L https://aistudio.google.com/
   curl -4 -s https://ipinfo.io/json | grep -E '"(country|org)"'
   Требование: loc == реальная страна сервера (не RU), aistudio == 200, org != российский хостер.
   ЕСЛИ IP «грязный» (loc=RU, или aistudio!=200, или org российский) — ОСТАНОВИСЬ и скажи пользователю
   пересоздать сервер у не-российского хостера. НЕ продолжай настройку.
2. НЕ ПОТЕРЯЙ SSH. Перед `ufw enable` разреши порт 22. Перед отключением паролей проверь вход по ключу
   ОТДЕЛЬНОЙ сессией. `xray -test` перед каждым рестартом.
</hard_gates>

<instructions>
Выполни по шагам, показывая результат каждого:

1. Проверь SSH-доступ, зафиксируй ОС/архитектуру. Выполни <hard_gates> п.1.
2. Установи xray-core (официальный установщик; для supply-chain-гигиены можно закрепить версию `... @ install --version <тег>`):
   bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
3. Сгенерируй секреты: `xray uuid`; `xray x25519` (PrivateKey + Password/PublicKey); два shortId `openssl rand -hex 8`.
4. Проверь REALITY_DEST. TLS 1.3 — необходимо, но НЕ достаточно: некоторые TLS1.3-сайты (www.microsoft.com!) Reality НЕ может «одолжить» и хендшейк ломается.
   openssl s_client -connect REALITY_DEST:443 -servername REALITY_DEST -tls1_3 </dev/null 2>/dev/null | grep Protocol
   Проверенные рабочие dest: www.samsung.com, dl.google.com, addons.mozilla.org. Если сомневаешься — после шага 5 подними временный xray-клиент и убедись, что через сервер реально ходит трафик (curl ifconfig), а не падает в fallback.
5. Запиши /usr/local/etc/xray/config.json: inbound VLESS :443, security=reality, flow=xtls-rprx-vision,
   dest/serverNames=REALITY_DEST, privateKey + оба shortId; sniffing routeOnly=true;
   outbound freedom с domainStrategy=UseIPv4 (форс IPv4 — иначе утечка на IPv6 и страновой бан) + blackhole;
   dns queryStrategy=UseIPv4; routing: блок bittorrent, geosite:category-ads-all, geoip:private.
   Сделай бэкап старого конфига, затем `xray -test` и рестарт. Проверь `ss -tlnp | grep :443`.
6. Тюнинг (/etc/sysctl.d/99-xray.conf): BBR (fq + tcp_congestion_control=bbr), tcp_fastopen=3,
   увеличенные буферы. Подними LimitNOFILE=1048576 через systemd drop-in для xray. Применить, рестарт.
7. Безопасность (в этом порядке): `ufw allow 22/tcp` и `ufw allow 443/tcp`, затем `ufw --force enable`;
   fail2ban для sshd (maxretry=5, bantime=1h); unattended-upgrades. Проверь, что SSH жив (whoami по SSH).
8. SSH-хардненинг: drop-in с PasswordAuthentication no, PubkeyAuthentication yes, PermitRootLogin prohibit-password.
   `sshd -t`, reload, и ОБЯЗАТЕЛЬНО проверь новый вход по ключу отдельной сессией.
9. Собери vless-ссылку:
   vless://UUID@SERVER_IP:443?security=reality&encryption=none&pbk=PUBLICKEY&fp=chrome&sni=REALITY_DEST&sid=SHORTID1&type=tcp&flow=xtls-rprx-vision#NODE_NAME
   Сгенерь QR: ANSI в терминал (`qrencode -t ANSIUTF8 "<ссылка>"`) и PNG-файл.
10. Сгенерируй клиентский конфиг Shadowrocket по <client_config_spec>.
11. Финальная проверка: xray active, `xray -test` OK, :443 слушает и доступен снаружи,
    <hard_gates> п.1 повторно (openai-api `curl -4 https://api.openai.com/v1/models` == 401 = регион ок).
12. Сохрани все данные (IP, ключи, ссылку, что настроено) в отдельный файл creds и НАПОМНИ не пушить его в git.
</instructions>

<client_config_spec>
Сгенерируй файл shadowrocket.conf. Порядок правил критичен (Shadowrocket = first-match, побеждает ПЕРВОЕ совпадение):
- [General]: ipv6=false; DNS через рабочий из РФ DoH (dns.comss.one) + 77.88.8.8; fallback-dns-server=77.88.8.8 (НЕ system — иначе утечка в DNS провайдера).
- [Proxy]: если WORK_WG_FILE задан — прочитай ключи из этого файла и добавь Work-WG (wireguard, endpoint, ключи).
- [Proxy Group]: Switch = select, NODE_NAME   (плюс другие узлы, если пользователь их добавит).
- [Rule] строго сверху вниз:
  1) Защита от петель: IP-CIDR SERVER_IP/32 -> DIRECT; и IP WG-эндпоинта -> DIRECT.
  2) Локальные подсети -> DIRECT.
  3) Глушилка QUIC: AND,((PROTOCOL,UDP),(DST-PORT,443)),REJECT-NO-DROP   (ключевое слово DST-PORT!).
  4) Apple/App Store домены (apple.com, icloud.com, icloud-content.com, mzstatic.com, cdn-apple.com, apple-dns.net, apple-cloudkit.com, aaplimg.com) -> DIRECT.
  5) OpenAI (openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com) -> NODE_NAME (жёстко).
  6) Google (google.com, googleapis.com, gstatic.com, googleusercontent.com, ggpht.com) -> NODE_NAME (жёстко).
  7) Капча входа в ChatGPT (arkoselabs.com, challenges.cloudflare.com) -> NODE_NAME (тот же выход, что сессия).
  8) Если WORK_IPS задан — их IP-CIDR -> Work-WG.
  9) РФ напрямую ВЫШЕ рекламы: RULE-SET РФ-банки и ip-checker (misha-tgshv) -> DIRECT.
  10) RULE-SET реклама/приватность (blackmatrix7) -> REJECT (ПОСЛЕ п.9, иначе adblock отрежет банк по ложному срабатыванию).
  11) GEOIP,RU,DIRECT.
  12) FINAL,Switch.
- [MITM]: enable=false.
Отдай пользователю содержимое файла и краткую инструкцию по импорту (добавить узел по vless-ссылке
с именем ровно NODE_NAME, импортировать конфиг, Global Routing=Config).
</client_config_spec>

<constraints>
- Реализуй ТОЛЬКО описанное. Никаких лишних панелей (3x-ui), доменов, сертификатов, доп. портов.
- REALITY_DEST не должен быть за Cloudflare (его в РФ троттлят) — если пользователь дал Cloudflare-домен, предупреди и предложи www.samsung.com. НЕ используй www.microsoft.com — он отдаёт TLS1.3, но Reality не может одолжить его хендшейк (проверено).
- Всегда форсируй IPv4-выход (UseIPv4). Никогда не оставляй пароли включёнными после хардненинга.
- БЕЗОПАСНОСТЬ СЕКРЕТОВ (важно): НИКОГДА не выводи приватные ключи (Reality privateKey, WireGuard privateKey/presharedKey) в чат — всё, что ты пишешь в ответ, видит LLM-провайдер и его логи. Пиши секреты напрямую на сервере в creds-файл под `umask 077`. В ответе показывай только ПУБЛИЧНОЕ: vless-ссылку (pbk публичен by design), QR, IP. Если задан WORK_WG_FILE — читай ключи из этого файла на диске, НЕ из тела промпта.
- Генерируй shortId случайно (`openssl rand -hex 8`), не бери литералы из примеров.
- Если шаг упал — покажи реальный вывод ошибки и останови цепочку, не «чини» вслепую.
</constraints>

<output_format>
В конце верни одним блоком:
1. Итог по серверу: IP, страна/ASN, статус проверки OpenAI/Google (✅/❌).
2. Что настроено: версия xray, dest, хардненинг (ufw/fail2ban/ssh), тюнинг (bbr/tfo).
3. vless-ссылку и QR (ANSI + путь к PNG).
4. Полное содержимое shadowrocket.conf в кодблоке.
5. Чек-лист проверки для пользователя (ifconfig.me, вход в ChatGPT, App Store).
6. Явное напоминание: creds-файл и *.conf в git не коммитить.
</output_format>
````

---

## Часть 3. После работы агента

1. Проверь creds-файл, скопируй vless-ссылку/QR в надёжное место (менеджер паролей).

2. **Импорт в Shadowrocket** (iOS/macOS; приложение платное, ~$2.99 в App Store; бесплатная альтернатива — Streisand):
   1. Добавь узел: главный экран → «+» (вверху справа) → вставь vless-ссылку **или** отсканируй QR. Имя узла должно быть ровно `NODE_NAME`.
   2. Импортируй конфиг: скопируй `shadowrocket.conf` на устройство (AirDrop / файл / ссылка) и открой его в Shadowrocket, либо на macOS перетащи в приложение.
   3. Внизу: **Global Routing → Config** (чтобы работали правила из конфига, а не «весь трафик в прокси»).
   4. Включи тумблер сверху. Появится группа **Switch** — если серверов несколько, тапом выбираешь активный.

3. **Проверка:** открой `ifconfig.me` — должен показать IP сервера; зайди в ChatGPT (вход через Google) — без `unsupported_country`; App Store — ищется и грузится.

4. Секреты (`*.conf`, creds, ключи) держи только локально — в публичный git не пушь (см. `.gitignore`).

---

## Если не работает

| Симптом | Что сделать |
|---------|-------------|
| ChatGPT пишет `unsupported_country` | IP сервера в блок-листе. Удали VPS (Destroy) и создай новый — IP сменится; повтори промпт. |
| Ничего не грузится при включённом VPN | Проверь: Global Routing = **Config**; имя добавленного узла ровно = `NODE_NAME` (по нему конфиг находит сервер); тумблер включён. |
| Группа `Switch` пустая / «узел не найден» | Имя узла в приложении не совпало с `NODE_NAME` — переименуй узел ровно в это имя (регистр важен). |
| App Store/банк «висят» | DNS. Убедись, что в конфиге `dns-server` = рабочий из РФ DoH (dns.comss.one), а не Cloudflare/Google (их душит ТСПУ). |
| Медленно или рвётся соединение | Если серверов несколько — переключи сервер в группе `Switch`. Иначе проверь на сервере: `systemctl status xray`, нагрузку, и что dest не за Cloudflare. |
| Совсем нет доступа по SSH после настройки | Хардненинг отключил пароли — заходи только по ключу `~/.ssh/xray_key`. Ключ должен быть на той машине, откуда подключаешься. |

Серверные проблемы (xray не стартует, порт закрыт) — раздел «Типовые ошибки» в [xray-vpn-deployment-guide.md](xray-vpn-deployment-guide.md).
