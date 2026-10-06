"""Общая логика: приём отчётов, рассылка уведомлений, сторож пропусков, утренняя сводка."""
from __future__ import annotations

import asyncio
import logging
import math
import uuid
from datetime import datetime, timedelta
from pathlib import Path

from aiogram import Bot
from aiogram.exceptions import (TelegramBadRequest, TelegramForbiddenError, TelegramMigrateToChat,
                                TelegramNotFound, TelegramRetryAfter)
from aiohttp import web

from . import views
from .config import Config
from .db import DB, RunReport, from_iso, utcnow

log = logging.getLogger(__name__)

VALID_STATUS = ("ok", "warning", "error")
# Ошибки, при которых повтор не поможет: сообщение отбрасываем, чтобы не застопорить очередь
PERMANENT_ERRORS = (TelegramBadRequest, TelegramForbiddenError, TelegramNotFound, TelegramMigrateToChat)
# Отметка о задержке, если сообщение пролежало в очереди дольше этого
LATE_DELIVERY = timedelta(minutes=10)
INT64_MAX = 2**63 - 1
# страница установки агента и архив агента (собирается deploy.ps1)
STATIC_DIR = Path(__file__).parent / "static"
AGENT_ZIP = "backup-agent.zip"


class Service:
    def __init__(self, cfg: Config, db: DB, bot: Bot):
        self.cfg = cfg
        self.db = db
        self.bot = bot
        self._bg: set[asyncio.Task] = set()
        self._flush_lock = asyncio.Lock()
        self._last_prune: datetime | None = None

    # ---------- отправка ----------
    # Все сообщения сначала пишутся в outbox (SQLite), потом доставляются по порядку.
    # Если Telegram/VPN недоступен — сообщения ждут в базе и уходят, когда связь вернётся.
    def enqueue(self, text: str, silent: bool = False) -> None:
        for chat_id in self.cfg.notify_chat_ids:
            for part in views.split_message(text):
                self.db.outbox_add(chat_id, part, silent)

    async def send_all(self, text: str, silent: bool = False) -> None:
        self.enqueue(text, silent)
        await self.flush_outbox()

    async def flush_outbox(self) -> None:
        """Доставляет очередь. Если доставка уже идёт — та же итерация заберёт и новые сообщения."""
        if self._flush_lock.locked():
            return
        async with self._flush_lock:
            while (msg := self.db.outbox_next()) is not None:
                text = msg["text"]
                delay = utcnow() - from_iso(msg["created_at"])
                if delay > LATE_DELIVERY:
                    text += f"\n<i>⌛ доставлено с задержкой {views.fmt_age(delay)}</i>"
                try:
                    await self.bot.send_message(msg["chat_id"], text, disable_notification=bool(msg["silent"]))
                except TelegramRetryAfter as e:
                    await asyncio.sleep(e.retry_after)
                    continue
                except PERMANENT_ERRORS as e:
                    log.error("сообщение в %s отброшено (%s): %.200s", msg["chat_id"], e, msg["text"])
                except Exception as e:  # сеть/прокси/Telegram недоступен — оставляем в очереди
                    log.warning("Telegram недоступен (%s), в очереди сообщений: %d", e, self.db.outbox_size())
                    return
                self.db.outbox_delete(msg["id"])

    async def outbox_loop(self, every_sec: int = 15) -> None:
        while True:
            try:
                await self.flush_outbox()
            except Exception:
                log.exception("ошибка доставки очереди")
            await asyncio.sleep(every_sec)

    def background(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._bg.add(task)
        task.add_done_callback(self._bg.discard)

    # ---------- приём отчётов ----------
    @staticmethod
    def parse_report(data: dict) -> RunReport:
        def opt_float(key):
            v = data.get(key)
            if v in (None, ""):
                return None
            f = float(v)
            if not math.isfinite(f):
                raise ValueError(f"{key}: ожидается конечное число")
            return f

        def opt_int(key):
            f = opt_float(key)
            if f is None:
                return None
            if abs(f) > INT64_MAX:
                raise ValueError(f"{key}: слишком большое число")
            return int(f)

        def opt_dt(key):
            v = data.get(key)
            if not v:
                return None
            s = str(v).strip().replace("Z", "+00:00")
            dt = datetime.fromisoformat(s)
            if dt.tzinfo is None:
                raise ValueError(f"{key}: нужен часовой пояс в дате")
            return dt

        job = str(data.get("job") or "").strip()
        if not job or len(job) > 100:
            raise ValueError("job: обязательное поле, до 100 символов")
        status = str(data.get("status") or "").strip().lower()
        if status not in VALID_STATUS:
            raise ValueError(f"status: одно из {VALID_STATUS}")
        interval = opt_float("interval_hours")
        if interval == 0:
            pass   # 0 — служебное задание без расписания (например, применение jobs.psd1): сторож не следит
        else:
            interval = min(max(interval or 24.0, 0.1), 24 * 100)
        finished = opt_dt("finished") or utcnow()
        # защита от «будущих» отчётов из-за сбитых часов
        if finished > utcnow() + timedelta(minutes=10):
            finished = utcnow()
        message = data.get("message")
        if message is not None:
            message = str(message)[-8000:]
        host = data.get("host")
        archive = data.get("archive")
        return RunReport(
            run_uid=str(data.get("run_id") or uuid.uuid4())[:64],
            job=job,
            host=str(host)[:100] if host else None,
            status=status,
            exit_code=opt_int("exit_code"),
            started=opt_dt("started"),
            finished=finished,
            duration_sec=opt_float("duration_sec"),
            size_bytes=opt_int("size_bytes"),
            files=opt_int("files"),
            free_bytes=opt_int("free_bytes"),
            archive=str(archive)[:500] if archive else None,
            interval_hours=interval,
            message=message,
            method=str(data.get("method") or "").strip().lower()[:20] or None,
        )

    async def handle_report(self, request: web.Request) -> web.Response:
        try:
            data = await request.json()
            if not isinstance(data, dict):
                raise ValueError
        except Exception:
            return web.json_response({"ok": False, "error": "ожидается JSON-объект"}, status=400)

        token = request.headers.get("X-Token") or str(data.get("token") or "")
        company = self.db.company_by_token(token.strip())
        if company is None:
            log.warning("отчёт с неизвестным токеном от %s", request.remote)
            return web.json_response({"ok": False, "error": "неверный токен"}, status=401)

        try:
            rep = self.parse_report(data)
        except (ValueError, TypeError) as e:
            return web.json_response({"ok": False, "error": str(e)}, status=400)

        if self.db.run_exists(rep.run_uid):
            return web.json_response({"ok": True, "duplicate": True})

        # аномально маленький архив при «успешном» статусе — повод насторожиться
        if rep.status == "ok" and rep.size_bytes is not None and self.cfg.size_drop_ratio > 0:
            typical = self.db.typical_size(company["id"], rep.job)
            if typical and rep.size_bytes < typical * self.cfg.size_drop_ratio:
                rep.status = "warning"
                rep.notes = (f"архив {views.fmt_size(rep.size_bytes)} — заметно меньше обычного "
                             f"({views.fmt_size(typical)})")

        res = self.db.record_run(company["id"], rep)
        if res is None:
            return web.json_response({"ok": True, "duplicate": True})

        log.info("отчёт: %s / %s — %s", company["name"], rep.job, rep.status)
        status = res.run["status"]
        if status != "ok" or self.cfg.notify_success or res.prev_state in (None, "warning", "error", "missed"):
            text = views.run_notification(company["name"], res.job, res.run, res.prev_state,
                                          res.is_latest, self.cfg.tz)
            silent = status == "ok" and self.cfg.success_silent and res.prev_state == "ok"
            # в базу — сразу, до ответа агенту; доставка — в фоне
            self.enqueue(text, silent=silent)
            self.background(self.flush_outbox())
        return web.json_response({"ok": True, "status": status})

    async def handle_ping(self, request: web.Request) -> web.Response:
        """Проверка токена установщиком агента: отвечает названием компании."""
        company = self.db.company_by_token((request.headers.get("X-Token") or "").strip())
        if company is None:
            log.warning("ping с неизвестным токеном от %s", request.remote)
            return web.json_response({"ok": False, "error": "неверный токен"}, status=401)
        return web.json_response({"ok": True, "company": company["name"]})

    @staticmethod
    async def handle_index(request: web.Request) -> web.Response:
        return web.FileResponse(STATIC_DIR / "index.html", headers={"Cache-Control": "no-cache"})

    @staticmethod
    async def handle_agent_zip(request: web.Request) -> web.StreamResponse:
        path = STATIC_DIR / AGENT_ZIP
        if not path.is_file():
            raise web.HTTPNotFound(text="архив агента не собран (deploy.ps1 собирает его при деплое)")
        return web.FileResponse(path, headers={"Content-Disposition": f'attachment; filename="{AGENT_ZIP}"',
                                               "Cache-Control": "no-cache"})

    @staticmethod
    async def handle_health(request: web.Request) -> web.Response:
        return web.json_response({"ok": True})

    def web_app(self) -> web.Application:
        app = web.Application(client_max_size=256 * 1024)
        app.router.add_post("/api/report", self.handle_report)
        app.router.add_get("/health", self.handle_health)
        app.router.add_route("*", "/api/ping", self.handle_ping)
        app.router.add_get("/", self.handle_index)
        app.router.add_get(f"/{AGENT_ZIP}", self.handle_agent_zip)
        return app

    # ---------- сторож пропусков ----------
    async def check_missed(self) -> None:
        now = utcnow()
        for job in self.db.all_jobs():
            if job["paused"] or not job["last_finished"] or job["interval_hours"] <= 0:
                continue
            last = from_iso(job["last_finished"])
            allowed = timedelta(hours=job["interval_hours"] * self.cfg.grace_factor,
                                minutes=self.cfg.grace_minutes)
            if now - last < allowed:
                continue
            if job["state"] != "missed":
                self.db.set_job_state(job["id"], "missed", now)
                await self.send_all(views.missed_notification(self.db.get_job(job["id"]), self.cfg.tz, False))
            else:
                notified = from_iso(job["missed_notified_at"])
                if self.cfg.missed_repeat_hours > 0 and (
                        notified is None or now - notified >= timedelta(hours=self.cfg.missed_repeat_hours)):
                    self.db.set_job_state(job["id"], "missed", now)
                    await self.send_all(views.missed_notification(job, self.cfg.tz, True))

    def prune_if_due(self) -> None:
        """Чистка старой истории раз в сутки (не зависит от того, включена ли утренняя сводка)."""
        now = utcnow()
        if self._last_prune and now - self._last_prune < timedelta(days=1):
            return
        self._last_prune = now
        removed = self.db.prune_runs(self.cfg.runs_keep_days)
        if removed:
            log.info("удалено старых запусков: %d", removed)

    async def watchdog_loop(self, every_sec: int = 300) -> None:
        while True:
            try:
                await self.check_missed()
                self.prune_if_due()
            except Exception:
                log.exception("ошибка сторожа")
            await asyncio.sleep(every_sec)

    # ---------- утренняя сводка ----------
    def _next_summary(self) -> datetime:
        h, m = self.cfg.summary_time
        now = datetime.now(self.cfg.tz)
        target = now.replace(hour=h, minute=m, second=0, microsecond=0)
        if target <= now:
            target += timedelta(days=1)
        return target

    async def summary_loop(self) -> None:
        if not self.cfg.summary_time:
            return
        while True:
            target = self._next_summary()
            await asyncio.sleep(max(1.0, (target - datetime.now(self.cfg.tz)).total_seconds()))
            try:
                await self.check_missed()
                text, _ = views.summary_view(self.db, self.cfg.tz, title="Утренняя сводка")
                await self.send_all(text)
            except Exception:
                log.exception("ошибка утренней сводки")
            await asyncio.sleep(61)
