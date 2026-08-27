<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/hero-dark.svg">
    <img src=".github/assets/hero-light.svg" alt="tunnel-kit — свой VPN на VLESS + Reality с раздельным туннелированием" width="820">
  </picture>
</p>

<p align="center">
  <img src="https://img.shields.io/github/last-commit/Kjaly/tunnel-kit?style=flat-square&label=обновлён&color=1a7f37" alt="Последний коммит">
  <img src="https://img.shields.io/badge/протокол-VLESS%20%2B%20Reality-0969da?style=flat-square" alt="Протокол">
  <img src="https://img.shields.io/badge/сервер-Ubuntu%2022.04%20%C2%B7%2024.04-e95420?style=flat-square" alt="ОС сервера">
  <img src="https://img.shields.io/github/license/Kjaly/tunnel-kit?style=flat-square&label=лицензия&color=8250df" alt="Лицензия">
</p>

<p align="center">
  <a href="#быстрый-старт">Быстрый старт</a> ·
  <a href="#как-устроен-трафик">Как устроен трафик</a> ·
  <a href="xray-vpn-deployment-guide.md">Полный гайд</a> ·
  <a href="optional-enhancements.md">Улучшения</a> ·
  <a href="#скрипты">Скрипты</a>
</p>

---

Личный VPN, который обходит ТСПУ/DPI и открывает ChatGPT с Google, но при этом **не ломает App Store, банки и госуслуги** — российские ресурсы идут напрямую, мимо туннеля.

## Быстрый старт

Три пути, один результат. Выбери по тому, сколько времени готов потратить.

| Путь | Что открыть | Время |
|------|-------------|-------|
| **Есть ИИ-агент с доступом к терминалу** | [`ai-setup-prompt.md`](ai-setup-prompt.md) — заполняешь пару полей, даёшь SSH, агент делает всё сам | ~15 мин |
| **Хочу понять и сделать руками** | [`xray-vpn-deployment-guide.md`](xray-vpn-deployment-guide.md) — пошаговая инструкция от создания VPS | ~1 час |
| **Уже работает, хочу больше** | [`optional-enhancements.md`](optional-enhancements.md) — 9 независимых апгрейдов | по желанию |

Перед установкой — одна проверка, которая экономит вечер. IP сервера должен «читаться» как не-российский:

```bash
ssh root@SERVER_IP 'curl -4 -s https://chatgpt.com/cdn-cgi/trace | grep -E "^(ip|loc)="; \
  curl -4 -s -o /dev/null -w "aistudio: %{http_code}\n" -L https://aistudio.google.com/'
```

`loc` должен совпасть с реальной страной сервера, `aistudio` — отдать `200`. Если нет — меняй хостера, дальше идти бессмысленно ([почему](#выбор-хостера-решает-всё)).

## Как устроен трафик

Смысл всей затеи — **не гнать через VPN всё подряд**. Российские сервисы ломаются от зарубежного IP, а AI-сервисы наоборот требуют «чистый» не-российский ASN.

```mermaid
flowchart LR
    D["Устройство"] --> R{"Правила<br/>маршрутизации"}

    R -->|"OpenAI · Google AI"| C["SERVER-CLEAN<br/><i>жёстко, не переключается</i>"]
    R -->|"Apple · банки · .ru · GeoIP RU"| DIR(["DIRECT<br/><i>мимо VPN</i>"])
    R -->|"рабочие IP (опц.)"| WG["WireGuard"]
    R -->|"реклама · трекеры"| REJ(["REJECT"])
    R -->|"всё остальное"| SW["Switch<br/><i>любой из серверов</i>"]

    C --> NET(("Интернет"))
    SW --> NET
    WG --> CORP(("Корп. сеть"))
    DIR --> NET
```

| Трафик | Куда | Почему так |
|--------|------|------------|
| OpenAI, Google/Gemini | `SERVER-CLEAN` | нужен не-российский ASN, и переключать этот узел нельзя |
| Apple/App Store, РФ-банки, `.ru`, GeoIP RU | **DIRECT** | с зарубежного IP они ломаются или требуют подтверждений |
| Выбранные IP/сети *(опц.)* | WireGuard | рабочие и корпоративные ресурсы |
| Реклама, трекеры | **REJECT** | бонусом |
| Всё остальное | группа `Switch` | переключение сервера в один тап |

## Выбор хостера решает всё

> [!IMPORTANT]
> OpenAI и Google блокируют не по стране на карте, а по **ASN/геобазе IP**. Российский хостер — даже с сервером физически в Амстердаме — отдаёт `error_code: unsupported_country`, потому что его автономная система помечена как RU. Cloudflare при этом может показывать `loc=NL`; не ориентируйся на него.

- Бери **не-российский** хостер: DigitalOcean, Vultr, Contabo, OVH. Локация NL/DE/FI.
- Избегай российских хостеров с зарубежными локациями — для AI не заработает.
- Бери с почасовой оплатой: если IP окажется в блок-листе, пересоздай сервер и получи новый.

## Сервер

```bash
# 1. Установить xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 2. Сгенерировать ключи
xray uuid           # -> UUID
xray x25519         # -> PrivateKey / Password(PublicKey)
openssl rand -hex 8 # -> shortId
```

Дальше — `/usr/local/etc/xray/config.json`: VLESS + Reality, `flow: xtls-rprx-vision`, `dest`/`serverNames` на проверенный TLS 1.3-сайт и `outbound.freedom.domainStrategy = UseIPv4`. Полный шаблон — в [гайде](xray-vpn-deployment-guide.md).

<details>
<summary><b>Выбор Reality-<code>dest</code> — здесь спотыкаются чаще всего</b></summary>

<br>

TLS 1.3 сам по себе **не гарантия**: Reality должен уметь «одолжить» хендшейк сайта.

| | Домен | Причина |
|---|-------|---------|
| ✅ | `www.samsung.com` | проверен, не за Cloudflare |
| ✅ | `dl.google.com` | проверен |
| ✅ | `addons.mozilla.org` | проверен |
| ✅ | `www.nvidia.com` | проверен |
| ❌ | `www.microsoft.com` | TLS 1.3 есть, но хендшейк не одалживается → клиент падает в fallback |
| ❌ | `*.cloudflare.com`, `discord.com` | за Cloudflare, а его ТСПУ троттлит |
| ❌ | `google.com`, любые `.ru` | слишком заметно |

После настройки **обязательно** проверь реальным клиентом, что трафик идёт через сервер, а не падает в fallback на `dest`: подними временный xray-клиент и сделай `curl ifconfig.me` через socks — должен вернуться IP твоего сервера.

</details>

<details>
<summary><b>Минимальный хардненинг</b></summary>

<br>

BBR + TCP Fast Open, `ufw` (22 + 443), `fail2ban`, `unattended-upgrades`, SSH только по ключу.

Готовые команды и cloud-init — в [`xray-vpn-deployment-guide.md`](xray-vpn-deployment-guide.md), разделы 3 и 12.

</details>

## Клиент

1. Добавь узлы по vless-ссылкам. Имя узла после `#` должно совпадать с именем в конфиге — например `SERVER-CLEAN`, `SERVER-ALT`.
2. Скопируй [`shadowrocket.conf.example`](shadowrocket.conf.example) в свой `.conf`, подставь значения.
3. Импортируй конфиг, поставь Global Routing = **Config**.
4. Группа **Switch** переключает сервер для обычного трафика; AI-домены жёстко на `SERVER-CLEAN`.

> [!TIP]
> Переезжаешь с телефона на роутер? Правила Shadowrocket и маршруты WireGuard конвертируются скриптами — [раздел 8](optional-enhancements.md#8-перенос-на-роутер-xkeen). Там же разобраны две ловушки XKeen, которые выглядят как «всё настроено, но глючит».

## Что можно добавить сверху

Каждое независимо и необязательно. Команды и подробности — в [`optional-enhancements.md`](optional-enhancements.md).

| № | Улучшение | Что даёт |
|---|-----------|----------|
| 1 | [Подписка](optional-enhancements.md#1-subscription-сервер) | узлы обновляются на всех устройствах сами |
| 2 | [Мониторинг и авто-восстановление](optional-enhancements.md#2-мониторинг--авто-восстановление) | чинит упавший сервис, ведёт лог |
| 3 | [Telegram-алерты](optional-enhancements.md#3-telegram-алерты) | 🟢 ок · 🟡 авто-починка · 🔴 критично |
| 4 | [Кросс-серверный чек туннеля](optional-enhancements.md#4-сквозной-кросс-серверный-чек-туннеля) | ловит поломку Reality, которую сервисный чек не видит |
| 5 | [Бэкап конфигов](optional-enhancements.md#5-бэкап-конфигов) | пересобрать сервер за минуты |
| 6 | [Учёт трафика по пользователям](optional-enhancements.md#6-учёт-трафика-по-пользователям) | видно, кто сколько съел; алерт до овереджа хостера |
| 7 | [Интерактивный Telegram-бот](optional-enhancements.md#7-интерактивный-telegram-бот) | управление сервером из чата, без SSH |
| 8 | [Перенос на роутер (XKeen)](optional-enhancements.md#8-перенос-на-роутер-xkeen) | VPN для всей домашней сети — конвертеры готовы, гайд скоро |

> [!NOTE]
> **Скоро:** пошаговая инструкция по установке XKeen на роутер — Entware на USB, ветки для белого и серого IP, что ломается при обновлении прошивки. Сейчас в разделе 8 лежат два конвертера: они снимают ручную работу по переносу правил, но саму установку пока описывают только в общих чертах.

<details>
<summary><b>Что умеет бот и почему он не работает под root</b></summary>

<br>

| Группа | Команды |
|--------|---------|
| Инфо | `/status` · `/traffic` · `/day` · `/month` · `/users` · `/top` |
| Доступ | `/link` · `/qr` · `/adduser` · `/deluser` · `/quota` |
| Операции | `/restart` · `/logs` · `/backup` |

Бот — обычный процесс без прав, а не root-демон с токеном в чате:

```mermaid
flowchart LR
    TG["Telegram<br/><i>ALLOWED_CHAT_IDS</i>"] --> BOT["vpnbot.py<br/><b>user: vpnbot</b><br/><i>без шелла, не root</i>"]
    BOT -->|"sudo -n · whitelist из 5 подкоманд"| CTL["vpnctl.sh<br/><b>root</b>"]
    CTL -->|"бэкап → test → restart → автооткат"| CFG["config.json"]
    BOT -.->|"только чтение"| ST["Stats API<br/>127.0.0.1:10085"]
```

- `/etc/sudoers.d/vpnbot` — фиксированный whitelist из пяти подкоманд, никакого `NOPASSWD: ALL`. Файл проверяется `visudo -c` **до** установки.
- Токен в `/etc/vpnbot/bot.conf` (600, владелец `vpnbot`), а не в `/root` — каталог `/root` закрыт правами 700 на уровне каталога.
- Пустой `ALLOWED_CHAT_IDS` = бот не отвечает никому.
- Каждая правка `config.json` идёт через бэкап → `xray run -test` → рестарт → проверку `:443` → автооткат при провале.

</details>

## Структура репозитория

| Файл | Назначение |
|------|-----------|
| [`ai-setup-prompt.md`](ai-setup-prompt.md) | чек-лист и промпт: отдаёшь ИИ-агенту с SSH — настраивает под ключ |
| [`xray-vpn-deployment-guide.md`](xray-vpn-deployment-guide.md) | подробная серверная инструкция руками |
| [`optional-enhancements.md`](optional-enhancements.md) | девять необязательных апгрейдов: от подписки до роутера |
| [`shadowrocket.conf.example`](shadowrocket.conf.example) | шаблон клиентского конфига, без секретов |
| [`ru-direct.list`](ru-direct.list) | пример списка РФ-доменов для DIRECT |
| [`scripts/`](scripts/) | тринадцать готовых скриптов — см. ниже |

### Скрипты

<details>
<summary><b>Развернуть таблицу</b></summary>

<br>

| Скрипт | Где запускать | Что делает |
|--------|---------------|------------|
| [`vpn-healthcheck.sh`](scripts/vpn-healthcheck.sh) | сервер | проверка и авто-починка каждые 5 мин, алерты трёх уровней |
| [`tunnel-check.sh`](scripts/tunnel-check.sh) | сервер | сквозной чек туннеля до соседнего сервера |
| [`setup-telegram-alert.sh`](scripts/setup-telegram-alert.sh) | сервер | находит chat_id и включает алерты |
| [`backup-config.sh`](scripts/backup-config.sh) | сервер | один архив для пересборки сервера |
| [`enable-xray-stats.sh`](scripts/enable-xray-stats.sh) | сервер | Stats API и email-теги клиентам, идемпотентно, с автооткатом |
| [`vpn-usage-collect.sh`](scripts/vpn-usage-collect.sh) | сервер | копит per-user трафик помесячно, сверяет с личными квотами |
| [`vpn-traffic-alert.sh`](scripts/vpn-traffic-alert.sh) | сервер | пороги 80/95 % квоты хостера, `--report` · `--digest` · `--monthly` |
| [`install-traffic-monitor.sh`](scripts/install-traffic-monitor.sh) | сервер | ставит учёт трафика тремя таймерами |
| [`vpnbot.py`](scripts/vpnbot.py) | сервер | Telegram-бот, только stdlib, под непривилегированным пользователем |
| [`vpnctl.sh`](scripts/vpnctl.sh) | сервер | единственная точка привилегированных мутаций для бота |
| [`install-vpn-bot.sh`](scripts/install-vpn-bot.sh) | сервер | ставит бота, sudoers-whitelist и systemd-юнит |
| [`shadowrocket-to-xray.py`](scripts/shadowrocket-to-xray.py) | локально | правила Shadowrocket → routing для Xray/XKeen |
| [`wg-conf-to-routes.py`](scripts/wg-conf-to-routes.py) | локально | WireGuard `.conf` → статические маршруты роутера |

</details>

> [!NOTE]
> Реальные конфиги (`*.conf`), `vpn-credentials.md`, QR-коды и ключи перечислены в `.gitignore` и в репозиторий не попадают.

## Чек-лист после установки

- [ ] `systemctl is-active xray` → `active`
- [ ] порт 443 слушается: `ss -tln | grep :443`
- [ ] через VPN `curl ifconfig.me` отдаёт **IP сервера**
- [ ] через VPN `https://chatgpt.com/cdn-cgi/trace` показывает `loc` страны сервера, не `RU`
- [ ] РФ-сайт и банковское приложение открываются — значит DIRECT работает
- [ ] после `reboot` всё поднялось само: `systemctl is-active xray caddy vpn-healthcheck.timer`
- [ ] `pre-commit install` выполнен — коммит с ключом будет заблокирован

## Ротация ключей

Если vless-ссылка или ключи могли утечь — сервер пересоздавать не нужно:

```bash
# на сервере
NEW=$(xray x25519)                       # новый privateKey + Password(PublicKey)
NEWSID=$(openssl rand -hex 8)            # новый shortId
# впиши новый privateKey и shortId в /usr/local/etc/xray/config.json
xray -test -config /usr/local/etc/xray/config.json && systemctl restart xray
```

Затем собери новую vless-ссылку с новым `pbk` (Password) и `sid` и обнови узел в клиенте. Старая ссылка сразу перестанет работать.

## Словарь терминов

<details>
<summary><b>Развернуть, если термины незнакомы</b></summary>

<br>

| Термин | Что это |
|--------|---------|
| **VLESS** | протокол прокси — «транспорт» твоего трафика до сервера |
| **Reality** | маскировка: для цензора соединение выглядит как визит на чужой большой сайт |
| **XTLS-Vision** (`flow`) | ускоритель поверх Reality, меньше накладных расходов на HTTPS |
| **ТСПУ / DPI** | оборудование глубокого анализа трафика у провайдеров РФ, ищет и режет VPN |
| **ASN** | «сеть-владелец» IP-адреса; по нему OpenAI и Google определяют страну |
| **dest / SNI** | имя сайта, под который маскируется Reality: TLS 1.3, не за Cloudflare |
| **shortId / pbk** | параметры Reality в ссылке; `pbk` — публичный ключ, его можно передавать |
| **DoH** | DNS поверх HTTPS, чтобы провайдер не подменял ответы |
| **XKeen** | сборка Xray для роутеров Keenetic/Netcraze поверх Entware |

</details>

## Безопасность

- [`.pre-commit-config.yaml`](.pre-commit-config.yaml) включает секрет-сканер **gitleaks**. Поставь один раз — и коммит с ключом или токеном будет заблокирован:

  ```bash
  brew install pre-commit && pre-commit install
  ```

- Ключи, vless-ссылки и URL подписки — это доступ к твоему VPN. Не публикуй их; если утекли, [ротация](#ротация-ключей) занимает пару минут.
- Бэкап-архив содержит приватные ключи и токен бота — держи его только на сервере, права 600.

---

## Лицензия

[MIT](LICENSE) — используй, меняй и распространяй свободно, сохраняя копирайт.

---

<sub>Материал для законного обеспечения приватности и доступа к легальным сервисам. Соблюдай законы своей юрисдикции. Ключи и конфиги — только твои, не публикуй их.</sub>
