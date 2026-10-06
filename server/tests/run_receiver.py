"""Запуск только приёмника с фейковым Telegram (для теста агента): печатает уведомления в консоль."""
import asyncio, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from aiohttp import web
from aiogram import Bot
from smoke_test import FakeSession  # noqa
from backup_bot.config import load_config
from backup_bot.db import DB
from backup_bot.service import Service

class PrintSession(FakeSession):
    async def make_request(self, bot, method, timeout=None):
        print("----- TG -----\n" + getattr(method, "text", str(method)), flush=True)
        return await super().make_request(bot, method, timeout)

async def main():
    cfg = load_config(); db = DB(cfg.db_path)
    if not db.list_companies():
        print("TOKEN", db.add_company("ООО Тест"), flush=True)
    svc = Service(cfg, db, Bot(cfg.bot_token, session=PrintSession()))
    runner = web.AppRunner(svc.web_app()); await runner.setup()
    await web.TCPSite(runner, cfg.listen_host, cfg.listen_port).start()
    await asyncio.Event().wait()
asyncio.run(main())
