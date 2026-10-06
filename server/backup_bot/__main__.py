"""Точка входа: python -m backup_bot"""
from __future__ import annotations

import asyncio
import logging
import ssl

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.enums import ParseMode
from aiogram.exceptions import TelegramUnauthorizedError
from aiogram.types import BotCommand
from aiohttp import web

from .config import load_config
from .db import DB
from .handlers import build_routers
from .service import Service

log = logging.getLogger("backup_bot")


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = load_config()
    if not cfg.admin_ids:
        log.warning("ADMIN_IDS пуст — бот никому не ответит. Напишите боту, он покажет ваш id.")

    db = DB(cfg.db_path)
    session = AiohttpSession(proxy=cfg.telegram_proxy) if cfg.telegram_proxy else None
    if cfg.telegram_proxy:
        log.info("Telegram через прокси %s", cfg.telegram_proxy)
    bot = Bot(cfg.bot_token, session=session,
              default=DefaultBotProperties(parse_mode=ParseMode.HTML, link_preview_is_disabled=True))
    svc = Service(cfg, db, bot)

    dp = Dispatcher()
    for router in build_routers(svc):
        dp.include_router(router)

    # HTTP-приёмник отчётов
    ssl_ctx = None
    if cfg.ssl_cert and cfg.ssl_key:
        ssl_ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_ctx.load_cert_chain(cfg.ssl_cert, cfg.ssl_key)
    runner = web.AppRunner(svc.web_app(), access_log=None)
    await runner.setup()
    await web.TCPSite(runner, cfg.listen_host, cfg.listen_port, ssl_context=ssl_ctx).start()
    log.info("приёмник отчётов слушает %s://%s:%d/api/report",
             "https" if ssl_ctx else "http", cfg.listen_host, cfg.listen_port)

    # Приёмник уже работает. Ждём, пока станет доступен Telegram (например, поднимается VPN).
    while True:
        try:
            me = await bot.get_me()
            log.info("подключён к Telegram как @%s", me.username)
            break
        except TelegramUnauthorizedError:
            raise SystemExit("Неверный BOT_TOKEN")
        except Exception as e:
            log.warning("Telegram недоступен (%s), повтор через 15 с", e)
            await asyncio.sleep(15)

    tasks = [asyncio.create_task(svc.watchdog_loop()), asyncio.create_task(svc.summary_loop()),
             asyncio.create_task(svc.outbox_loop())]
    try:
        await bot.set_my_commands([
            BotCommand(command="summary", description="Сводка"),
            BotCommand(command="problems", description="Проблемы"),
            BotCommand(command="companies", description="Компании"),
            BotCommand(command="add_company", description="Добавить компанию"),
            BotCommand(command="tokens", description="Токены компаний"),
            BotCommand(command="help", description="Помощь"),
        ])
    except Exception as e:
        log.warning("не удалось задать меню команд: %s", e)

    try:
        await dp.start_polling(bot)
    finally:
        for t in tasks:
            t.cancel()
        await runner.cleanup()
        await bot.session.close()


if __name__ == "__main__":
    asyncio.run(main())
