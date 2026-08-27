#!/usr/bin/env python3
"""Интерактивный Telegram-бот для tunnel-kit. Только stdlib, long polling (getUpdates).

Работает под непривилегированным пользователем vpnbot. Все мутации (adduser/deluser/
set-quota/restart/backup) идут ТОЛЬКО через `sudo -n vpnctl.sh <...>` — см.
/etc/sudoers.d/vpnbot. Сам бот файлы xray не трогает и root не требует.

Конфиг: /etc/vpnbot/bot.conf (BOT_TOKEN, ALLOWED_CHAT_IDS, PRIMARY_EMAIL, SERVER_LABEL,
SERVER_IP, IFACE) — копия нужных полей из /root/vpn-alert.conf, т.к. /root закрыт
для vpnbot (700, root:root) на уровне каталога, а не только файла.
"""
import datetime
import html
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONF = "/etc/vpnbot/bot.conf"
OFFSET_FILE = "/var/lib/vpnbot/offset"
CFG = "/usr/local/etc/xray/config.json"
USERS = "/var/lib/vpn-usage/users.json"
USAGE_DIR = "/var/lib/vpn-usage"
HEALTH_LOG = "/var/log/vpn-health.log"
VPNCTL = "/usr/local/bin/vpnctl.sh"


def log(msg):
    print(f"{datetime.datetime.now(datetime.timezone.utc).isoformat()} {msg}", flush=True)


def load_conf(path):
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip()
    except FileNotFoundError:
        log(f"нет конфига {path}")
    return conf


def default_primary_email():
    try:
        cfg = json.load(open(CFG))
        for ib in cfg.get("inbounds", []):
            if ib.get("protocol") == "vless":
                clients = ib["settings"]["clients"]
                if clients:
                    return clients[0]["email"]
    except Exception:
        pass
    return ""


CONF_DATA = load_conf(CONF)
BOT_TOKEN = CONF_DATA.get("BOT_TOKEN", "")
ALLOWED_CHAT_IDS = {int(x) for x in CONF_DATA.get("ALLOWED_CHAT_IDS", "").split(",") if x.strip()}
PRIMARY_EMAIL = CONF_DATA.get("PRIMARY_EMAIL") or default_primary_email()
SERVER_LABEL = CONF_DATA.get("SERVER_LABEL", "VPN")
SERVER_IP = CONF_DATA.get("SERVER_IP", "")
IFACE = CONF_DATA.get("IFACE", "eth0")

if not BOT_TOKEN:
    log("BOT_TOKEN пуст — проверь /etc/vpnbot/bot.conf")
    sys.exit(1)
if not ALLOWED_CHAT_IDS:
    log("ALLOWED_CHAT_IDS пуст — бот не ответит НИКОМУ, проверь /etc/vpnbot/bot.conf")

API = f"https://api.telegram.org/bot{BOT_TOKEN}"


# ── Telegram API (stdlib, без requests) ──────────────────────────────────
def api_call(method, params=None, timeout=20):
    data = urllib.parse.urlencode(params or {}).encode()
    req = urllib.request.Request(f"{API}/{method}", data=data)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def send_message(chat_id, text, reply_markup=None):
    params = {"chat_id": chat_id, "text": text, "parse_mode": "HTML"}
    if reply_markup:
        params["reply_markup"] = json.dumps(reply_markup)
    try:
        api_call("sendMessage", params)
    except Exception as e:
        log(f"sendMessage error: {e}")


def edit_message(chat_id, message_id, text, reply_markup=None):
    params = {"chat_id": chat_id, "message_id": message_id, "text": text, "parse_mode": "HTML"}
    if reply_markup:
        params["reply_markup"] = json.dumps(reply_markup)
    try:
        api_call("editMessageText", params)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="ignore")
        if "message is not modified" not in body:
            log(f"editMessageText error: {e} {body}")
    except Exception as e:
        log(f"editMessageText error: {e}")


def chat_action(chat_id, action="typing"):
    try:
        api_call("sendChatAction", {"chat_id": chat_id, "action": action})
    except Exception:
        pass


def answer_callback(cq_id, text=None, show_alert=False):
    params = {"callback_query_id": cq_id}
    if text:
        params["text"] = text
        params["show_alert"] = "true" if show_alert else "false"
    try:
        api_call("answerCallbackQuery", params)
    except Exception:
        pass


def send_photo_file(chat_id, path, caption=None):
    boundary = "----vpnbotBoundary"
    head = f"--{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{chat_id}\r\n"
    if caption:
        head += f"--{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n{caption}\r\n"
    with open(path, "rb") as f:
        img = f.read()
    tail = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"qr.png\"\r\n"
            f"Content-Type: image/png\r\n\r\n").encode() + img + f"\r\n--{boundary}--\r\n".encode()
    body = head.encode() + tail
    req = urllib.request.Request(f"{API}/sendPhoto", data=body)
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except Exception as e:
        log(f"sendPhoto error: {e}")
        return None


def curl_get(url, timeout=8):
    try:
        r = subprocess.run(["curl", "-4", "-s", "--max-time", str(timeout), url],
                            capture_output=True, text=True, timeout=timeout + 3)
        return r.stdout.strip()
    except Exception:
        return ""


def run_vpnctl(chat_id, args, message_id=None):
    chat_action(chat_id)
    try:
        r = subprocess.run(["sudo", "-n", VPNCTL] + args, capture_output=True, text=True, timeout=30)
        out = (r.stdout + r.stderr).strip() or "(пусто)"
    except Exception as e:
        out = f"ошибка запуска vpnctl: {e}"
    text = f"<pre>{html.escape(out)}</pre>"
    if message_id:
        edit_message(chat_id, message_id, text)
    else:
        send_message(chat_id, text)


def ask_confirm(chat_id, action_key, prompt):
    kb = {"inline_keyboard": [[
        {"text": "✅ Да", "callback_data": f"confirm:{action_key}"},
        {"text": "✖️ Отмена", "callback_data": "cancel"},
    ]]}
    send_message(chat_id, prompt, reply_markup=kb)


# ── VLESS-ссылка для клиента ──────────────────────────────────────────────
def build_vless_link(email):
    try:
        cfg = json.load(open(CFG))
        ib = next(x for x in cfg["inbounds"] if x.get("protocol") == "vless")
        client = next((c for c in ib["settings"]["clients"] if c["email"] == email), None)
        if not client:
            return None
        port = ib.get("port", 443)
        rs = ib["streamSettings"]["realitySettings"]
        sni = rs["serverNames"][0]
        sid = rs["shortIds"][0]
        priv = rs["privateKey"]
        out = subprocess.run(["xray", "x25519", "-i", priv], capture_output=True, text=True, timeout=10).stdout
        pubkey = ""
        for line in out.splitlines():
            if line.startswith("Password (PublicKey):"):
                pubkey = line.split(":", 1)[1].strip()
        if not pubkey:
            return None
        params = {"security": "reality", "sni": sni, "fp": "chrome",
                  "pbk": pubkey, "sid": sid, "type": "tcp", "flow": client.get("flow", "")}
        qs = urllib.parse.urlencode(params)
        label = urllib.parse.quote(f"{SERVER_LABEL}-{email}")
        return f"vless://{client['id']}@{SERVER_IP}:{port}?{qs}#{label}"
    except Exception as e:
        log(f"build_vless_link error: {e}")
        return None


# ── статистика по пользователям ───────────────────────────────────────────
def month_usage():
    month = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")
    try:
        data = json.load(open(os.path.join(USAGE_DIR, f"{month}.json")))
    except Exception:
        data = {}
    try:
        quotas = json.load(open(USERS))
    except Exception:
        quotas = {}
    rows = []
    for email, v in data.items():
        gib = (v.get("uplink", 0) + v.get("downlink", 0)) / 1073741824
        rows.append((email, gib, quotas.get(email, {}).get("quota_gib")))
    rows.sort(key=lambda x: -x[1])
    return rows, month


def format_rows(rows):
    if not rows:
        return "  (данных пока нет)"
    lines = []
    for email, gib, q in rows:
        qtxt = f" / {q} ГиБ" if q else ""
        lines.append(f"  • {html.escape(email)}: {gib:.2f} ГиБ{qtxt}")
    return "\n".join(lines)


# ── команды ────────────────────────────────────────────────────────────────
HELP_TEXT = """<b>tunnel-kit bot</b>

<b>Инфо:</b>
/status — xray, exit IP, регион, load/RAM/uptime
/traffic — квота за месяц, темп, прогноз
/day, /month — сырой трафик vnstat
/users, /top — расход по пользователям за месяц

<b>Доступ:</b>
/link [имя] — vless:// ссылка (по умолчанию — основной клиент)
/qr [имя] — то же самое QR-картинкой
/adduser &lt;имя&gt; — новый клиент
/deluser &lt;имя&gt; — удалить (с подтверждением)
/quota &lt;имя&gt; &lt;ГиБ&gt; — личный лимит трафика, 0 = снять

<b>Операции:</b>
/restart — перезапуск xray (с подтверждением)
/logs — последние строки журнала xray и health-check
/backup — снять бэкап конфигов"""


def cmd_help(chat_id, args):
    send_message(chat_id, HELP_TEXT)


STATUS_REFRESH_KB = {"inline_keyboard": [[{"text": "🔄 Обновить", "callback_data": "refresh:status"}]]}


def render_status_text():
    active = subprocess.run(["systemctl", "is-active", "--quiet", "xray"]).returncode == 0
    ss_out = subprocess.run(["ss", "-tln"], capture_output=True, text=True).stdout
    listening = ":443 " in ss_out
    exit_ip = curl_get("https://ifconfig.me") or "?"
    trace = curl_get("https://chatgpt.com/cdn-cgi/trace")
    loc = "?"
    for line in trace.splitlines():
        if line.startswith("loc="):
            loc = line.split("=", 1)[1].strip()
    load1 = open("/proc/loadavg").read().split()[0]
    mem_total = mem_avail = 0
    for line in open("/proc/meminfo"):
        if line.startswith("MemTotal:"):
            mem_total = int(line.split()[1])
        elif line.startswith("MemAvailable:"):
            mem_avail = int(line.split()[1])
    mem_used_mb = (mem_total - mem_avail) / 1024
    mem_total_mb = mem_total / 1024
    uptime_s = float(open("/proc/uptime").read().split()[0])
    days, rem = divmod(uptime_s, 86400)
    hours, _ = divmod(rem, 3600)
    icon = "🟢" if active and listening else "🔴"
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S UTC")
    return (f"{icon} <b>xray</b>: {'активен' if active else 'НЕ активен'}"
            f"{', :443 слушает' if listening else ', :443 НЕ слушает'}\n"
            f"🌍 exit IP: <code>{html.escape(exit_ip)}</code> · регион (OpenAI): {html.escape(loc)}\n"
            f"⚙️ load: {load1} · RAM: {mem_used_mb:.0f}/{mem_total_mb:.0f} МБ\n"
            f"⏱ uptime: {int(days)}д {int(hours)}ч\n"
            f"<i>обновлено {now}</i>")


def cmd_status(chat_id, args):
    chat_action(chat_id)
    send_message(chat_id, render_status_text(), reply_markup=STATUS_REFRESH_KB)


def cmd_traffic(chat_id, args):
    chat_action(chat_id)
    r = subprocess.run(["/usr/local/bin/vpn-traffic-alert.sh", "--dry"],
                        capture_output=True, text=True, timeout=30)
    send_message(chat_id, f"<pre>{html.escape(r.stdout.strip() or r.stderr.strip())}</pre>")


def cmd_day(chat_id, args):
    chat_action(chat_id)
    r = subprocess.run(["vnstat", "--json", "d", "--limit", "1", "-i", IFACE],
                        capture_output=True, text=True, timeout=10)
    try:
        day = json.loads(r.stdout)["interfaces"][0]["traffic"]["day"][-1]
        rx = day.get("rx", 0) / 1073741824
        tx = day.get("tx", 0) / 1073741824
        total = rx + tx
        d = day["date"]
        date_str = f"{d['year']:04d}-{d['month']:02d}-{d['day']:02d}"
        now = datetime.datetime.now(datetime.timezone.utc)
        elapsed_h = max(now.hour + now.minute / 60, 0.25)
        rate_mbit = total * 8192 / (elapsed_h * 3600)
        proj = total / elapsed_h * 24
        text = (f"📅 <b>{date_str}</b>\n"
                f"⬇️ rx: {rx:.2f} ГиБ · ⬆️ tx: {tx:.2f} ГиБ\n"
                f"Итого: <b>{total:.2f}</b> ГиБ · ~{rate_mbit:.1f} Мбит/с в среднем\n"
                f"Прогноз к концу суток: ~{proj:.2f} ГиБ")
    except Exception as e:
        text = f"Не получилось разобрать vnstat: {html.escape(str(e))}"
    send_message(chat_id, text)


def cmd_month(chat_id, args):
    chat_action(chat_id)
    r = subprocess.run(["vnstat", "--json", "m", "--limit", "1", "-i", IFACE],
                        capture_output=True, text=True, timeout=10)
    try:
        m = json.loads(r.stdout)["interfaces"][0]["traffic"]["month"][-1]
        rx = m.get("rx", 0) / 1073741824
        tx = m.get("tx", 0) / 1073741824
        total = rx + tx
        d = m["date"]
        date_str = f"{d['year']:04d}-{d['month']:02d}"
        text = (f"🗓 <b>{date_str}</b>\n"
                f"⬇️ rx: {rx:.2f} ГиБ · ⬆️ tx: {tx:.2f} ГиБ\n"
                f"Итого (сырой vnstat): <b>{total:.2f}</b> ГиБ\n"
                f"<i>С учётом квоты и поправки — /traffic</i>")
    except Exception as e:
        text = f"Не получилось разобрать vnstat: {html.escape(str(e))}"
    send_message(chat_id, text)


def cmd_users(chat_id, args):
    rows, month = month_usage()
    send_message(chat_id, f"<b>Пользователи за {month}:</b>\n{format_rows(rows)}")


def cmd_top(chat_id, args):
    rows, month = month_usage()
    send_message(chat_id, f"<b>Топ-5 за {month}:</b>\n{format_rows(rows[:5])}")


def cmd_link(chat_id, args):
    email = args[0] if args else PRIMARY_EMAIL
    link = build_vless_link(email)
    if not link:
        send_message(chat_id, f"Пользователь <code>{html.escape(email)}</code> не найден.")
        return
    send_message(chat_id, f"<code>{html.escape(link)}</code>")


def cmd_qr(chat_id, args):
    email = args[0] if args else PRIMARY_EMAIL
    link = build_vless_link(email)
    if not link:
        send_message(chat_id, f"Пользователь <code>{html.escape(email)}</code> не найден.")
        return
    chat_action(chat_id, "upload_photo")
    if not shutil.which("qrencode"):
        send_message(chat_id, "На сервере нет qrencode: <code>apt-get install -y qrencode</code>")
        return
    path = f"/tmp/vpnbot-qr-{os.getpid()}.png"
    try:
        subprocess.run(["qrencode", "-o", path, "-s", "8", link], check=True, timeout=10)
        send_photo_file(chat_id, path, caption=email)
    except Exception as e:
        send_message(chat_id, f"Не получилось собрать QR: {html.escape(str(e))}")
    finally:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass


def cmd_adduser(chat_id, args):
    if not args:
        send_message(chat_id, "Использование: /adduser <имя>")
        return
    name = args[0]
    chat_action(chat_id)
    r = subprocess.run(["sudo", "-n", VPNCTL, "adduser", name], capture_output=True, text=True, timeout=30)
    out = (r.stdout + r.stderr).strip() or "(пусто)"
    send_message(chat_id, f"<pre>{html.escape(out)}</pre>")
    if r.returncode == 0:
        link = build_vless_link(name)
        if link:
            send_message(chat_id, f"<code>{html.escape(link)}</code>")


def cmd_deluser(chat_id, args):
    if not args:
        send_message(chat_id, "Использование: /deluser <имя>")
        return
    name = args[0]
    ask_confirm(chat_id, f"deluser:{name}",
                f"Удалить <code>{html.escape(name)}</code>? Оборвёт активное соединение, если оно есть.")


def cmd_quota(chat_id, args):
    if len(args) < 2:
        send_message(chat_id, "Использование: /quota <имя> <ГиБ> (0 = снять лимит)")
        return
    run_vpnctl(chat_id, ["set-quota", args[0], args[1]])


def cmd_restart(chat_id, args):
    ask_confirm(chat_id, "restart", "Перезапустить xray? Активные соединения оборвутся.")


def cmd_logs(chat_id, args):
    chat_action(chat_id)
    j = subprocess.run(["journalctl", "-u", "xray", "-n", "25", "--no-pager"],
                        capture_output=True, text=True).stdout
    try:
        health = "".join(open(HEALTH_LOG).readlines()[-15:])
    except Exception:
        health = "(лог health-check пуст)"
    text = (f"<b>journalctl xray (25):</b>\n<pre>{html.escape(j[-3000:])}</pre>\n"
            f"<b>vpn-health.log (15):</b>\n<pre>{html.escape(health[-1500:])}</pre>")
    send_message(chat_id, text)


def cmd_backup(chat_id, args):
    run_vpnctl(chat_id, ["backup"])


COMMANDS = {
    "/start": cmd_help, "/help": cmd_help,
    "/status": cmd_status, "/traffic": cmd_traffic,
    "/day": cmd_day, "/month": cmd_month,
    "/users": cmd_users, "/top": cmd_top,
    "/link": cmd_link, "/qr": cmd_qr,
    "/adduser": cmd_adduser, "/deluser": cmd_deluser, "/quota": cmd_quota,
    "/restart": cmd_restart, "/logs": cmd_logs, "/backup": cmd_backup,
}

# Список для нативного меню "/" в Telegram-клиенте (setMyCommands).
# Регистрируется ТОЛЬКО в разрешённых чатах (scope=chat) — случайный человек,
# открывший бота, меню с возможностями не увидит (глобальный scope остаётся пустым).
BOT_COMMANDS = [
    ("start", "Список команд"),
    ("help", "Список команд"),
    ("status", "xray, exit IP, регион, load/RAM/uptime"),
    ("traffic", "Квота за месяц, темп, прогноз"),
    ("day", "Трафик за сегодня (vnstat)"),
    ("month", "Трафик за месяц (vnstat)"),
    ("users", "Расход по пользователям за месяц"),
    ("top", "Топ-5 пользователей за месяц"),
    ("link", "vless:// ссылка клиента"),
    ("qr", "QR-код ссылки"),
    ("adduser", "Добавить клиента"),
    ("deluser", "Удалить клиента (с подтверждением)"),
    ("quota", "Личный лимит трафика, 0 = снять"),
    ("restart", "Перезапустить xray (с подтверждением)"),
    ("logs", "Последние строки логов xray/health-check"),
    ("backup", "Снять бэкап конфигов"),
]


BOT_DESCRIPTION = ("Приватная панель управления VPN-сервером tunnel-kit: статус xray, трафик, "
                    "пользователи, ссылки/QR, бэкапы. Отвечает только в разрешённых чатах.")
BOT_SHORT_DESCRIPTION = "tunnel-kit VPN: статус, трафик, управление"


def register_bot_profile():
    cmds = [{"command": c, "description": d} for c, d in BOT_COMMANDS]
    try:
        api_call("setMyCommands", {"commands": json.dumps([])})
    except Exception as e:
        log(f"setMyCommands(default) error: {e}")
    for chat_id in ALLOWED_CHAT_IDS:
        scope = {"type": "chat", "chat_id": chat_id}
        try:
            api_call("setMyCommands", {"commands": json.dumps(cmds), "scope": json.dumps(scope)})
        except Exception as e:
            log(f"setMyCommands(chat={chat_id}) error: {e}")
    try:
        api_call("setMyDescription", {"description": BOT_DESCRIPTION})
    except Exception as e:
        log(f"setMyDescription error: {e}")
    try:
        api_call("setMyShortDescription", {"short_description": BOT_SHORT_DESCRIPTION})
    except Exception as e:
        log(f"setMyShortDescription error: {e}")


# ── диспетчер апдейтов ────────────────────────────────────────────────────
def handle_message(msg):
    chat_id = msg["chat"]["id"]
    if chat_id not in ALLOWED_CHAT_IDS:
        return  # чужие чаты — молча игнорируем
    text = (msg.get("text") or "").strip()
    if not text.startswith("/"):
        return
    parts = text.split()
    cmd = parts[0].split("@")[0].lower()
    args = parts[1:]
    handler = COMMANDS.get(cmd)
    if handler:
        try:
            handler(chat_id, args)
        except Exception as e:
            log(f"handler {cmd} error: {e}")
            send_message(chat_id, f"Ошибка выполнения команды: {html.escape(str(e))}")
    else:
        send_message(chat_id, "Неизвестная команда. /help")


def handle_callback(cq):
    chat_id = cq["message"]["chat"]["id"]
    if chat_id not in ALLOWED_CHAT_IDS:
        return
    data = cq.get("data", "")
    cq_id = cq["id"]
    message_id = cq["message"]["message_id"]

    if data == "cancel":
        # всплывающий поп-ап вместо отдельного сообщения "Отменено." — меньше мусора в чате
        answer_callback(cq_id, text="Отменено", show_alert=False)
        return

    if data == "refresh:status":
        answer_callback(cq_id)
        edit_message(chat_id, message_id, render_status_text(), reply_markup=STATUS_REFRESH_KB)
        return

    answer_callback(cq_id)
    if data == "confirm:restart":
        edit_message(chat_id, message_id, "⏳ Перезапускаю xray...")
        run_vpnctl(chat_id, ["restart"], message_id=message_id)
    elif data.startswith("confirm:deluser:"):
        email = data.split(":", 2)[2]
        edit_message(chat_id, message_id, f"⏳ Удаляю <code>{html.escape(email)}</code>...")
        run_vpnctl(chat_id, ["deluser", email], message_id=message_id)
    elif data.startswith("askdel:"):
        # кнопка из алерта о превышении личной квоты (vpn-usage-collect.sh) —
        # переиспользует тот же confirm-flow, что и ручной /deluser
        email = data.split(":", 1)[1]
        ask_confirm(chat_id, f"deluser:{email}",
                    f"За месяц <code>{html.escape(email)}</code> превысил личную квоту. Отключить?")


def handle_update(upd):
    if "message" in upd:
        handle_message(upd["message"])
    elif "callback_query" in upd:
        handle_callback(upd["callback_query"])


# ── offset (персистится, чтобы рестарт не переигрывал команды) ───────────
def load_offset():
    try:
        with open(OFFSET_FILE) as f:
            return int(f.read().strip())
    except Exception:
        return 0


def save_offset(v):
    os.makedirs(os.path.dirname(OFFSET_FILE), exist_ok=True)
    tmp = OFFSET_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(v))
    os.replace(tmp, OFFSET_FILE)


def main():
    offset = load_offset()
    register_bot_profile()
    log(f"vpnbot стартовал, offset={offset}, allowed_chats={len(ALLOWED_CHAT_IDS)}")
    while True:
        try:
            result = api_call("getUpdates", {"offset": offset, "timeout": 30}, timeout=40)
            updates = result.get("result", [])
        except Exception as e:
            log(f"getUpdates error: {e}")
            time.sleep(5)
            continue
        for upd in updates:
            offset = upd["update_id"] + 1
            try:
                handle_update(upd)
            except Exception as e:
                log(f"handle_update error: {e}")
            save_offset(offset)


if __name__ == "__main__":
    main()
