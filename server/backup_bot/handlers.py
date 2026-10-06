"""Обработчики команд и кнопок бота."""
from __future__ import annotations

import sqlite3
from html import escape

from aiogram import F, Router
from aiogram.exceptions import TelegramBadRequest
from aiogram.filters import Command, CommandObject, CommandStart
from aiogram.types import CallbackQuery, InlineKeyboardMarkup, Message

from . import views
from .service import Service

HELP = (
    "<b>Мониторинг бекапов</b>\n\n"
    "Кнопки внизу:\n"
    f"{views.BTN_SUMMARY} — состояние всех компаний\n"
    f"{views.BTN_COMPANIES} — компании → задания → история\n"
    f"{views.BTN_PROBLEMS} — только то, что требует внимания\n\n"
    "Команды:\n"
    "/add_company <i>Название</i> — добавить компанию и получить токен для агента\n"
    "/rename_company <i>Старое</i> = <i>Новое</i> — переименовать\n"
    "/tokens — токены всех компаний\n"
    "/check — проверить пропуски прямо сейчас\n"
    "/id — показать ваш chat_id"
)


def build_routers(svc: Service) -> list[Router]:
    tz = svc.cfg.tz
    db = svc.db
    admins = svc.cfg.admin_ids

    admin = Router(name="admin")
    admin.message.filter(F.from_user.id.in_(admins))
    admin.callback_query.filter(F.from_user.id.in_(admins))

    async def show(target: Message | CallbackQuery, view: tuple[str, InlineKeyboardMarkup]) -> None:
        text, kb = view
        if isinstance(target, CallbackQuery):
            try:
                parts = views.split_message(text, views.MAX_LEN - 60)
                if len(parts) > 1:
                    text = parts[0] + "\n…\n<i>Список не поместился — отправьте команду ещё раз кнопкой внизу.</i>"
                await target.message.edit_text(text, reply_markup=kb)
            except TelegramBadRequest as e:
                if "message is not modified" not in str(e):
                    raise
            await target.answer()
        else:
            parts = views.split_message(text)
            for i, part in enumerate(parts):
                await target.answer(part, reply_markup=kb if i == len(parts) - 1 else None)

    # ----- команды -----
    @admin.message(CommandStart())
    @admin.message(Command("help"))
    async def cmd_start(m: Message):
        await m.answer(HELP, reply_markup=views.main_keyboard())

    @admin.message(Command("id"))
    async def cmd_id(m: Message):
        await m.answer(f"chat_id: <code>{m.chat.id}</code>")

    @admin.message(Command("summary"))
    @admin.message(F.text == views.BTN_SUMMARY)
    async def on_summary(m: Message):
        await show(m, views.summary_view(db, tz))

    @admin.message(Command("companies"))
    @admin.message(F.text == views.BTN_COMPANIES)
    async def on_companies(m: Message):
        await show(m, views.companies_view(db))

    @admin.message(Command("problems"))
    @admin.message(F.text == views.BTN_PROBLEMS)
    async def on_problems(m: Message):
        await show(m, views.problems_view(db, tz))

    @admin.message(Command("check"))
    async def cmd_check(m: Message):
        await svc.check_missed()
        await show(m, views.problems_view(db, tz))

    @admin.message(Command("add_company"))
    async def cmd_add_company(m: Message, command: CommandObject):
        name = (command.args or "").strip()
        if not name:
            await m.answer("Использование: <code>/add_company ООО Ромашка</code>")
            return
        try:
            token = db.add_company(name[:100])
        except sqlite3.IntegrityError:
            await m.answer("Компания с таким названием уже есть.")
            return
        await m.answer(
            f"🏢 Компания <b>{escape(name)}</b> добавлена.\n\n"
            f"Токен для агента (впишите в <code>agent.config.psd1</code> на машинах этой компании):\n"
            f"<code>{token}</code>"
        )

    @admin.message(Command("rename_company"))
    async def cmd_rename(m: Message, command: CommandObject):
        args = command.args or ""
        if "=" not in args:
            await m.answer("Использование: <code>/rename_company Старое название = Новое название</code>")
            return
        old, new = (s.strip() for s in args.split("=", 1))
        company = next((c for c in db.list_companies() if c["name"].lower() == old.lower()), None)
        if company is None or not new:
            await m.answer("Компания не найдена.")
            return
        try:
            db.rename_company(company["id"], new[:100])
        except sqlite3.IntegrityError:
            await m.answer("Такое название уже занято.")
            return
        await m.answer(f"Готово: <b>{escape(new)}</b>")

    @admin.message(Command("tokens"))
    async def cmd_tokens(m: Message):
        companies = db.list_companies()
        if not companies:
            await m.answer("Компаний пока нет.")
            return
        lines = ["🔑 <b>Токены компаний</b>"]
        lines += [f"<b>{escape(c['name'])}</b>\n<code>{c['token']}</code>" for c in companies]
        await m.answer("\n\n".join(lines))

    # ----- кнопки -----
    def arg(cb: CallbackQuery) -> int:
        return int(cb.data.split(":", 1)[1])

    @admin.callback_query(F.data == "sum")
    async def cb_summary(cb: CallbackQuery):
        await show(cb, views.summary_view(db, tz))

    @admin.callback_query(F.data == "pr")
    async def cb_problems(cb: CallbackQuery):
        await show(cb, views.problems_view(db, tz))

    @admin.callback_query(F.data == "cl")
    async def cb_companies(cb: CallbackQuery):
        await show(cb, views.companies_view(db))

    @admin.callback_query(F.data.startswith("c:"))
    async def cb_company(cb: CallbackQuery):
        await show(cb, views.company_view(db, arg(cb), tz))

    @admin.callback_query(F.data.startswith("ct:"))
    async def cb_company_token(cb: CallbackQuery):
        c = db.get_company(arg(cb))
        if c is None:
            await cb.answer("Компания не найдена", show_alert=True)
            return
        await cb.message.answer(f"🔑 <b>{escape(c['name'])}</b>\n<code>{c['token']}</code>")
        await cb.answer()

    @admin.callback_query(F.data.startswith("cd:"))
    async def cb_company_delete(cb: CallbackQuery):
        c = db.get_company(arg(cb))
        if c is None:
            await cb.answer("Уже удалена", show_alert=True)
            return
        text = (f"Удалить компанию <b>{escape(c['name'])}</b> со всеми заданиями и историей?\n"
                f"Агенты этой компании перестанут приниматься (токен станет недействительным).")
        await cb.message.edit_text(text, reply_markup=views.confirm_kb(f"cdy:{c['id']}", f"c:{c['id']}"))
        await cb.answer()

    @admin.callback_query(F.data.startswith("cdy:"))
    async def cb_company_delete_yes(cb: CallbackQuery):
        db.delete_company(arg(cb))
        await cb.answer("Компания удалена")
        await show(cb, views.companies_view(db))

    @admin.callback_query(F.data.startswith("j:"))
    async def cb_job(cb: CallbackQuery):
        await show(cb, views.job_view(db, arg(cb), tz))

    @admin.callback_query(F.data.startswith("jl:"))
    async def cb_job_log(cb: CallbackQuery):
        await show(cb, views.job_log_view(db, arg(cb), tz))

    @admin.callback_query(F.data.startswith("jp:"))
    async def cb_job_pause(cb: CallbackQuery):
        job_id = arg(cb)
        paused = db.toggle_pause(job_id)
        await cb.answer("Задание на паузе" if paused else "Пауза снята")
        await show(cb, views.job_view(db, job_id, tz))

    @admin.callback_query(F.data.startswith("jd:"))
    async def cb_job_delete(cb: CallbackQuery):
        j = db.get_job(arg(cb))
        if j is None:
            await cb.answer("Уже удалено", show_alert=True)
            return
        text = (f"Удалить задание <b>{escape(j['company_name'])} · {escape(j['name'])}</b> и его историю?\n"
                f"Если агент пришлёт новый отчёт, задание появится снова.")
        await cb.message.edit_text(text, reply_markup=views.confirm_kb(f"jdy:{j['id']}:{j['company_id']}",
                                                                        f"j:{j['id']}"))
        await cb.answer()

    @admin.callback_query(F.data.startswith("jdy:"))
    async def cb_job_delete_yes(cb: CallbackQuery):
        _, job_id, company_id = cb.data.split(":")
        db.delete_job(int(job_id))
        await cb.answer("Задание удалено")
        await show(cb, views.company_view(db, int(company_id), tz))

    # ----- всё остальное: чужие пользователи -----
    stranger = Router(name="stranger")

    @stranger.message()
    async def deny(m: Message):
        if m.from_user and m.from_user.id in admins:
            await m.answer("Не понял команду. Список команд: /help", reply_markup=views.main_keyboard())
            return
        await m.answer(
            "⛔ Нет доступа.\n"
            f"Ваш id: <code>{m.from_user.id}</code> — добавьте его в ADMIN_IDS на сервере и перезапустите бота."
        )

    @stranger.callback_query()
    async def deny_cb(cb: CallbackQuery):
        await cb.answer("Нет доступа", show_alert=True)

    return [admin, stranger]
