"""Smoke-тест без Telegram: фейковая сессия бота записывает все вызовы API."""
import asyncio
import os
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.client.session.base import BaseSession
from aiogram.exceptions import TelegramBadRequest, TelegramNetworkError
from aiogram.methods import AnswerCallbackQuery, EditMessageText, SendMessage, TelegramMethod
from aiogram.types import CallbackQuery, Chat, Message, Update, User
from aiohttp.test_utils import TestClient, TestServer

from backup_bot import views
from backup_bot.config import load_config
from backup_bot.db import DB, SCHEMA, to_iso
from backup_bot.handlers import build_routers
from backup_bot.service import AGENT_ZIP, STATIC_DIR, Service

ADMIN = 111


class FakeSession(BaseSession):
    def __init__(self):
        super().__init__()
        self.calls = []
        self.offline = False      # имитация недоступного Telegram/VPN
        self.reject_text = None   # имитация «битого» сообщения (400 Bad Request)

    async def make_request(self, bot, method: TelegramMethod, timeout=None):
        if self.offline:
            raise TelegramNetworkError(method, "offline")
        if self.reject_text and isinstance(method, SendMessage) and self.reject_text in method.text:
            raise TelegramBadRequest(method, "can't parse entities")
        self.calls.append(method)
        if isinstance(method, (SendMessage, EditMessageText)):
            # проверяем, что Telegram-HTML валиден
            check_html(method.text)
            return Message(message_id=len(self.calls), date=datetime.now(), chat=Chat(id=1, type="private"),
                           text=method.text)
        return True

    async def stream_content(self, *a, **kw):
        raise NotImplementedError

    async def close(self):
        pass


ALLOWED = {"b", "i", "code", "pre"}


class TagChecker(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []

    def handle_starttag(self, tag, attrs):
        assert tag in ALLOWED, tag
        self.stack.append(tag)

    def handle_endtag(self, tag):
        assert self.stack and self.stack.pop() == tag, f"unbalanced </{tag}>"


def check_html(text):
    assert len(text) <= 4096, len(text)
    p = TagChecker()
    p.feed(text)
    p.close()
    assert not p.stack, p.stack


def texts(session, since=0):
    return [c.text for c in session.calls[since:] if isinstance(c, (SendMessage, EditMessageText))]


async def main():
    tmp = tempfile.mkdtemp()
    os.environ.update(BOT_TOKEN="123:ABC", ADMIN_IDS=str(ADMIN), DB_PATH=f"{tmp}/t.db",
                      BACKUP_BOT_ENV=f"{tmp}/none.env")
    cfg = load_config()
    db = DB(cfg.db_path)
    session = FakeSession()
    bot = Bot(cfg.bot_token, session=session, default=DefaultBotProperties(parse_mode="HTML"))
    svc = Service(cfg, db, bot)

    token_a = db.add_company("ООО Альфа")
    token_b = db.add_company("ИП Петров <&>")
    db.add_company("Пустая компания")

    client = TestClient(TestServer(svc.web_app()))
    await client.start_server()

    now = datetime.now(timezone(timedelta(hours=3)))

    async def post(token, **kw):
        body = {"job": "1C_base", "host": "SRV-1C", "status": "ok", "exit_code": 0,
                "finished": now.isoformat(timespec="seconds"), "interval_hours": 24, **kw}
        r = await client.post("/api/report", json=body, headers={"X-Token": token})
        data = await r.json()
        await asyncio.sleep(0.05)  # дать фоновой отправке отработать
        return r.status, data

    # 1. ошибки валидации
    assert (await post("bad"))[0] == 401
    assert (await post(token_a, status="weird"))[0] == 400
    assert (await post(token_a, job=""))[0] == 400
    r = await client.post("/api/report", data=b"not json", headers={"X-Token": token_a})
    assert r.status == 400
    for bad in ({"interval_hours": "nan"}, {"size_bytes": "inf"}, {"duration_sec": "-inf"},
                {"size_bytes": 1e30}):
        assert (await post(token_a, **bad))[0] == 400, bad

    # 1.1. проверка токена установщиком
    r = await client.post("/api/ping", headers={"X-Token": token_b})
    assert r.status == 200 and (await r.json())["company"] == "ИП Петров <&>"
    r = await client.get("/api/ping", headers={"X-Token": "bad"})
    assert r.status == 401

    # 1.1.1. страница установки агента и архив агента
    r = await client.get("/")
    assert r.status == 200 and "Install.cmd" in await r.text()
    r = await client.get("/backup-agent.zip")
    assert r.status == (200 if (STATIC_DIR / AGENT_ZIP).is_file() else 404), r.status

    # 1.2. способ бекапа (снимок VSS) попадает в уведомление
    st, data = await post(token_b, job="Vss", run_id="vss1", method="vss")
    assert st == 200 and "📸 снимок VSS" in texts(session)[-1]

    # 1.3. миграция базы, созданной до колонки method
    old_db = f"{tmp}/old.db"
    conn = sqlite3.connect(old_db)
    conn.executescript(SCHEMA.replace(",\n    method        TEXT", ""))
    conn.close()
    assert "method" in {r["name"] for r in DB(old_db).conn.execute("PRAGMA table_info(runs)")}

    # 2. нормальные отчёты, история для медианы
    n0 = len(session.calls)
    for d in (5, 4, 3, 2):
        st, data = await post(token_a, run_id=f"r{d}", size_bytes=8_000_000_000 + d,
                              finished=(now - timedelta(days=d)).isoformat(timespec="seconds"),
                              duration_sec=875, free_bytes=120 * 2**30, files=1234)
        assert st == 200 and data["status"] == "ok", data
    sent = texts(session, n0)
    assert "🆕" in sent[0] and len(sent) == 4
    silent = [c.disable_notification for c in session.calls[n0:] if isinstance(c, SendMessage)]
    assert silent == [False, True, True, True], silent

    # 3. повторная доставка того же отчёта
    n0 = len(session.calls)
    st, data = await post(token_a, run_id="r2", size_bytes=1)
    assert data.get("duplicate") and len(session.calls) == n0

    # 4. маленький архив -> warning
    st, data = await post(token_a, run_id="small", size_bytes=1_000_000_000,
                          finished=(now - timedelta(days=1)).isoformat(timespec="seconds"))
    assert data["status"] == "warning", data
    assert "меньше обычного" in texts(session)[-1]

    # 5. ошибка 7z с кириллицей и html-символами
    st, data = await post(token_b, job="Docs", host="PC-<1>", status="error", exit_code=2,
                          message="ОШИБКА: не удаётся найти путь D:\\Docs <тест> & прочее\n" * 3)
    assert data["status"] == "error"
    assert "❌" in texts(session)[-1]

    # 6. восстановление после warning
    st, data = await post(token_a, run_id="rec", size_bytes=8_000_000_100)
    assert data["status"] == "ok"
    assert "восстановлено" in texts(session)[-1]

    # 7. запоздавший старый отчёт не меняет состояние
    st, data = await post(token_a, run_id="old", status="error", exit_code=2,
                          finished=(now - timedelta(days=10)).isoformat(timespec="seconds"))
    job = next(j for j in db.all_jobs() if j["name"] == "1C_base")
    assert job["state"] == "ok" and "старый отчёт" in texts(session)[-1]

    # 8. сторож: задание с последним отчётом 2 дня назад
    await post(token_a, job="Files", run_id="f1", interval_hours=24,
               finished=(now - timedelta(days=2)).isoformat(timespec="seconds"))
    # служебное задание без расписания (interval_hours=0) сторож не трогает
    await post(token_a, job="jobs.psd1", run_id="cfg1", interval_hours=0,
               finished=(now - timedelta(days=400)).isoformat(timespec="seconds"))
    assert next(j for j in db.all_jobs() if j["name"] == "jobs.psd1")["interval_hours"] == 0
    n0 = len(session.calls)
    await svc.check_missed()
    assert any("не пришёл вовремя" in t for t in texts(session, n0))
    assert not any("jobs.psd1" in t for t in texts(session, n0))
    n1 = len(session.calls)
    await svc.check_missed()       # повторно не дёргаем
    assert len(session.calls) == n1
    # имитируем, что напоминание было 25 ч назад
    files_job = next(j for j in db.all_jobs() if j["name"] == "Files")
    with db.conn:
        db.conn.execute("UPDATE jobs SET missed_notified_at=? WHERE id=?",
                        (to_iso(datetime.now(timezone.utc) - timedelta(hours=25)), files_job["id"]))
    await svc.check_missed()
    assert "Напоминание" in texts(session)[-1]

    # 8.1. Telegram недоступен: уведомление не теряется, а ждёт в outbox
    session.offline = True
    st, data = await post(token_a, job="Offline", run_id="off1", status="error", exit_code=2)
    assert st == 200 and db.outbox_size() == 1, db.outbox_size()
    await svc.flush_outbox()
    assert db.outbox_size() == 1
    session.offline = False
    n0 = len(session.calls)
    await svc.flush_outbox()
    assert db.outbox_size() == 0 and "Offline" in texts(session, n0)[0]
    # долго пролежавшее сообщение помечается задержкой
    svc.enqueue("старое")
    with db.conn:
        db.conn.execute("UPDATE outbox SET created_at=?", (to_iso(datetime.now(timezone.utc) - timedelta(hours=2)),))
    await svc.flush_outbox()
    assert "задержкой 2 ч" in texts(session)[-1]
    # «битое» сообщение отбрасывается и не блокирует очередь
    session.reject_text = "БИТОЕ"
    svc.enqueue("БИТОЕ")
    svc.enqueue("следующее")
    await svc.flush_outbox()
    session.reject_text = None
    assert db.outbox_size() == 0 and texts(session)[-1] == "следующее"

    # 8.2. длинный вывод из сплошных спецсимволов: после экранирования влезает в одно сообщение
    st, data = await post(token_a, job="Amp", run_id="amp1", status="error", exit_code=2,
                          message="&<>\n" * 3000)
    t = texts(session)[-1]
    assert t.count("<pre>") == 1 and "</pre>" in t, t[-200:]
    assert views.escape_trunc("a&b", 4) == "a…" and views.escape_trunc("a&b", 100) == "a&amp;b"

    # 9. экраны бота через диспетчер
    dp = Dispatcher()
    for r in build_routers(svc):
        dp.include_router(r)
    user = User(id=ADMIN, is_bot=False, first_name="Ivan")
    chat = Chat(id=ADMIN, type="private")
    uid = [1000]

    async def send_text(text, from_id=ADMIN):
        uid[0] += 1
        msg = Message(message_id=uid[0], date=datetime.now(), chat=chat,
                      from_user=User(id=from_id, is_bot=False, first_name="x"), text=text)
        n = len(session.calls)
        await dp.feed_update(bot, Update(update_id=uid[0], message=msg))
        return texts(session, n)

    async def press(data):
        uid[0] += 1
        msg = Message(message_id=1, date=datetime.now(), chat=chat, from_user=user, text="x")
        cb = CallbackQuery(id=str(uid[0]), from_user=user, chat_instance="ci", message=msg, data=data)
        n = len(session.calls)
        await dp.feed_update(bot, Update(update_id=uid[0], callback_query=cb))
        assert any(isinstance(c, AnswerCallbackQuery) for c in session.calls[n:]), data
        return texts(session, n)

    out = await send_text("/start")
    assert "Мониторинг" in out[0]
    out = await send_text(views.BTN_SUMMARY)
    print("\n===== СВОДКА =====\n" + out[0])
    assert "ИП Петров &lt;&amp;&gt;" in out[0] and "Пустая компания" in out[0]
    out = await send_text(views.BTN_PROBLEMS)
    print("\n===== ПРОБЛЕМЫ =====\n" + out[0])
    out = await send_text(views.BTN_COMPANIES)
    assert "Выберите" in out[0]
    out = await send_text("/add_company ООО Вега")
    assert "добавлена" in out[0]
    out = await send_text("/add_company ООО Вега")
    assert "уже есть" in out[0]
    out = await send_text("/rename_company ооо вега = ООО Вега-2")
    assert "Вега-2" in out[0]
    out = await send_text("/tokens")
    assert token_a in out[0]
    out = await send_text("привет")
    assert "/help" in out[0]
    out = await send_text("/start", from_id=999)
    assert "Нет доступа" in out[0] and "999" in out[0]

    cid = next(c for c in db.list_companies() if c["name"] == "ООО Альфа")["id"]
    jid = next(j for j in db.all_jobs() if j["name"] == "1C_base")["id"]
    out = await press("sum")
    out = await press("pr")
    out = await press("cl")
    out = await press(f"c:{cid}")
    print("\n===== КОМПАНИЯ =====\n" + out[0])
    out = await press(f"j:{jid}")
    print("\n===== ЗАДАНИЕ =====\n" + out[0])
    err_job = next(j for j in db.all_jobs() if j["name"] == "Docs")
    out = await press(f"jl:{err_job['id']}")
    print("\n===== ВЫВОД =====\n" + out[0])
    amp_job = next(j for j in db.all_jobs() if j["name"] == "Amp")
    out = await press(f"jl:{amp_job['id']}")
    assert out[0].count("<pre>") == 1 and len(out[0]) <= views.MAX_LEN
    await press(f"jp:{jid}")
    assert db.get_job(jid)["paused"] == 1
    await press(f"jp:{jid}")
    await press(f"ct:{cid}")
    await press(f"jd:{jid}")
    await press(f"jdy:{jid}:{cid}")
    assert db.get_job(jid) is None
    vega = next(c for c in db.list_companies() if c["name"] == "ООО Вега-2")
    await press(f"cd:{vega['id']}")
    await press(f"cdy:{vega['id']}")
    assert db.get_company(vega["id"]) is None
    await press("j:99999")  # несуществующее

    # 10. много заданий — сводка режется на части
    for i in range(150):
        await post(token_b, job=f"Job_{i:03}_с_длинным_названием", run_id=f"m{i}", status="error",
                   exit_code=2, message="x" * 300)
    out = await send_text(views.BTN_SUMMARY)
    assert len(out) > 1, len(out)
    await press("sum")   # edit — обрезается до лимита
    await press("pr")

    print("\n===== последнее уведомление-ошибка =====\n" + [t for t in texts(session) if "❌" in t][0])
    await client.close()
    print("\nALL OK, вызовов API:", len(session.calls))


if __name__ == "__main__":
    asyncio.run(main())
