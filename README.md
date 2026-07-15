# tunnel-kit

**Свой VPN для РФ на VLESS + Reality с раздельным туннелированием.** Обход DPI/ТСПУ, доступ к ChatGPT/Google, при этом App Store, банки и РФ-ресурсы — напрямую.

> ## 🚀 С чего начать
> - **Не хочешь разбираться, есть ИИ-агент с доступом к терминалу** → открой **[ai-setup-prompt.md](ai-setup-prompt.md)**. Это единственный нужный файл: заполняешь пару полей, даёшь SSH — агент настраивает всё сам.
> - **Хочешь понять и сделать руками** → **[xray-vpn-deployment-guide.md](xray-vpn-deployment-guide.md)** (подробная пошаговая инструкция).
> - **Уже работает, хочешь больше** → **[optional-enhancements.md](optional-enhancements.md)** (подписка, мониторинг, алерты — по желанию).
>
> Остальное ниже — как это устроено и почему.

Краткий практический гайд, как поднять личный VPN, который:

- **обходит ТСПУ/DPI** — протокол VLESS + Reality + XTLS-Vision (маскировка под чужой TLS-сайт);
- **не ломает App Store, банки и госуслуги** — российские ресурсы идут напрямую (DIRECT);
- **пускает ChatGPT и Google/Gemini** через сервер с «чистым» не-российским ASN;
- **умеет несколько серверов** с переключением в один тап (группа `Switch`).

Полная пошаговая инструкция по серверу — [xray-vpn-deployment-guide.md](xray-vpn-deployment-guide.md).
Готовый шаблон клиента — [shadowrocket.conf.example](shadowrocket.conf.example).

---

## Ключевой урок: выбор хостера решает всё

OpenAI и Google блокируют не по стране на карте, а по **ASN/геобазе IP**. Российский хостер
(даже с сервером физически в Амстердаме) отдаёт `error_code: unsupported_country`, потому что
его автономная система помечена как RU. Cloudflare при этом может показывать `loc=NL` — не
ориентируйся на него.

- ✅ Бери **не-российский** хостер: DigitalOcean, Vultr, Contabo, OVH и т.п. Локация NL/DE/FI.
- ❌ Избегай российских хостеров с зарубежными локациями (для AI не заработает).
- 💡 Бери с почасовой оплатой — если IP окажется в блок-листе, пересоздай сервер и получи новый.

Проверка «чистоты» IP до настройки:
```bash
ssh root@SERVER_IP 'curl -4 -s https://chatgpt.com/cdn-cgi/trace | grep -E "^(ip|loc)="; \
  curl -4 -s -o /dev/null -w "aistudio: %{http_code}\n" -L https://aistudio.google.com/'
```
`loc` должен совпасть с реальной страной сервера, aistudio — отдать `200`.

---

## Сервер (кратко)

```bash
# 1. Установить xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 2. Сгенерировать ключи
xray uuid          # -> UUID
xray x25519        # -> PrivateKey / Password(PublicKey)
openssl rand -hex 8 # -> shortId
```

Конфиг `/usr/local/etc/xray/config.json` — VLESS + Reality + `flow: xtls-rprx-vision`,
`dest`/`serverNames` на **проверенный** TLS 1.3-сайт (напр. `www.samsung.com` — **не** Cloudflare,
его в РФ троттлят; и **не** `www.microsoft.com` — Reality не может одолжить его хендшейк), и
`outbound.freedom.domainStrategy = UseIPv4` (иначе трафик может утечь в IPv6 и словить страновой
бан). Полный шаблон — в [гайде](xray-vpn-deployment-guide.md).

> ⚠️ Не всякий TLS 1.3-сайт годится как Reality-dest. После настройки обязательно проверь
> реальным клиентом, что трафик идёт через сервер, а не падает в fallback на dest.

Минимальный хардненинг: BBR + TCP Fast Open, `ufw` (22 + 443), `fail2ban`, `unattended-upgrades`,
SSH только по ключу. Команды — в [гайде](xray-vpn-deployment-guide.md).

---

## Клиент (Shadowrocket) с раздельным туннелированием

1. Добавь узлы по vless-ссылкам. Имя узла (после `#`) должно совпадать с именем в конфиге,
   напр. `SERVER-CLEAN`, `SERVER-ALT`.
2. Скопируй [shadowrocket.conf.example](shadowrocket.conf.example) в свой `.conf`, подставь значения.
3. Импортируй конфиг, поставь Global Routing = **Config**.
4. Группа **Switch** переключает сервер для обычного трафика; AI-домены жёстко на `SERVER-CLEAN`.

Логика маршрутизации из примера:

| Трафик | Куда |
|--------|------|
| OpenAI, Google (AI) | `SERVER-CLEAN` (жёстко, не переключается) |
| Apple / App Store, РФ-банки, РФ-домены, GeoIP RU | DIRECT |
| Рабочие IP | отдельный WireGuard (`Work-WG`) |
| Реклама / трекеры | REJECT |
| Всё остальное | группа `Switch` (выбор сервера) |

---

## Структура репозитория

| Файл | Назначение |
|------|-----------|
| `README.md` | этот гайд |
| `ai-setup-prompt.md` | чек-лист + готовый промпт: отдаёшь ИИ-агенту с SSH — настраивает всё под ключ |
| `xray-vpn-deployment-guide.md` | подробная серверная инструкция (руками) |
| `shadowrocket.conf.example` | шаблон клиентского конфига (без секретов) |
| `optional-enhancements.md` | необязательные апгрейды: подписка, мониторинг, Telegram-алерты |
| `scripts/` | готовые скрипты (health-check, Telegram-алерты) |
| `ru-direct.list` | пример списка РФ-доменов для DIRECT |

Реальные конфиги (`*.conf`), `vpn-credentials.md`, QR и ключи — в `.gitignore`, в репозиторий не попадают.

---

## Словарь терминов (если незнакомо)

- **VLESS** — протокол прокси, «транспорт» твоего трафика до сервера.
- **Reality** — маскировка: для цензора твоё соединение выглядит как обычный визит на чужой большой сайт (напр. samsung.com).
- **XTLS-Vision** (`flow`) — ускоритель поверх Reality, меньше накладных расходов на HTTPS.
- **ТСПУ / DPI** — оборудование глубокого анализа трафика у провайдеров РФ, которое ищет и режет VPN.
- **ASN** — «сеть-владелец» IP-адреса. По нему OpenAI/Google определяют страну и банят российские сети.
- **dest / SNI** — имя сайта, под который маскируется Reality (должно быть TLS 1.3, не за Cloudflare).
- **DoH** — DNS поверх HTTPS (шифрованный DNS), чтобы провайдер не подменял ответы.

> В промпте и конфиге менять нужно только **IP сервера** и **путь к SSH-ключу** — остальные значения рабочие, оставляй как есть.

---

## Ротация ключей (если ссылку/конфиг могли увидеть)

Если vless-ссылка или ключи утекли — смени их за пару минут, сервер пересоздавать не нужно:

```bash
# на сервере
NEW=$(xray x25519)                       # новый privateKey + Password(PublicKey)
NEWSID=$(openssl rand -hex 8)            # новый shortId
# впиши новый privateKey и shortId в /usr/local/etc/xray/config.json
xray -test -config /usr/local/etc/xray/config.json && systemctl restart xray
```

Затем собери новую vless-ссылку с новым `pbk` (Password) и `sid`, обнови узел в клиенте. Старая ссылка сразу перестанет работать.

Безопасность репозитория: `.pre-commit-config.yaml` включает секрет-сканер (gitleaks) — поставь `pre-commit install`, и коммит с ключом/IP будет заблокирован.

---

## Дисклеймер

Материал для законного обеспечения приватности и доступа к легальным сервисам.
Соблюдай законы своей юрисдикции. Ключи и конфиги — только твои, не публикуй их.
