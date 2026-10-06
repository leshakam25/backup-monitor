"""Тексты сообщений и клавиатуры бота."""
from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta
from html import escape
from zoneinfo import ZoneInfo

from aiogram.types import InlineKeyboardMarkup, KeyboardButton, ReplyKeyboardMarkup
from aiogram.utils.keyboard import InlineKeyboardBuilder

from .db import DB, from_iso, utcnow

ICON = {"ok": "✅", "warning": "⚠️", "error": "❌", "missed": "⏰", "paused": "⏸"}
STATUS_TEXT = {"ok": "успешно", "warning": "с предупреждениями", "error": "ошибка", "missed": "нет отчёта"}
SEVERITY = {"ok": 0, "paused": 0, "warning": 1, "missed": 2, "error": 3}

BTN_SUMMARY = "📊 Сводка"
BTN_COMPANIES = "🏢 Компании"
BTN_PROBLEMS = "⚠️ Проблемы"

MAX_LEN = 4000


def main_keyboard() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(
        keyboard=[[KeyboardButton(text=BTN_SUMMARY), KeyboardButton(text=BTN_COMPANIES),
                   KeyboardButton(text=BTN_PROBLEMS)]],
        resize_keyboard=True,
        is_persistent=True,
    )


# ---------- форматирование ----------
def fmt_size(b: int | None) -> str:
    if b is None:
        return "—"
    size = float(b)
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if size < 1024 or unit == "ТБ":
            return f"{size:.0f} {unit}" if unit in ("Б", "КБ") else f"{size:.1f} {unit}"
        size /= 1024
    return f"{b} Б"


def fmt_duration(sec: float | None) -> str:
    if sec is None:
        return "—"
    sec = int(sec)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h} ч {m} мин"
    if m:
        return f"{m} мин {s} с"
    return f"{s} с"


def fmt_age(delta: timedelta) -> str:
    minutes = int(delta.total_seconds() // 60)
    if minutes < 1:
        return "только что"
    if minutes < 60:
        return f"{minutes} мин"
    hours = minutes // 60
    if hours < 48:
        return f"{hours} ч"
    days, hours = divmod(hours, 24)
    return f"{days} дн {hours} ч" if hours else f"{days} дн"


def fmt_ago(delta: timedelta) -> str:
    age = fmt_age(delta)
    return age if age == "только что" else f"{age} назад"


def fmt_dt(dt: datetime | None, tz: ZoneInfo) -> str:
    if dt is None:
        return "—"
    local = dt.astimezone(tz)
    now = datetime.now(tz)
    return local.strftime("%d.%m %H:%M") if local.year == now.year else local.strftime("%d.%m.%Y %H:%M")


def fmt_interval(hours: float) -> str:
    if hours <= 0:
        return "без расписания"
    if hours >= 24 and hours % 24 == 0:
        days = int(hours // 24)
        return "раз в сутки" if days == 1 else f"раз в {days} дн"
    if hours < 1:
        return f"каждые {int(hours * 60)} мин"
    return f"каждые {hours:g} ч"


def job_state(job: sqlite3.Row) -> str:
    return "paused" if job["paused"] else job["state"]


def escape_trunc(text: str, limit: int) -> str:
    """Экранирует для HTML и обрезает до limit символов УЖЕ экранированного текста.
    Иначе &, <, > раздувают текст после обрезки и сообщение вылезает за лимит Telegram."""
    s = escape(text)
    if len(s) <= limit:
        return s
    s = s[: limit - 1]
    amp = s.rfind("&")
    if amp != -1 and ";" not in s[amp:]:   # не оставляем обрубок сущности вида &am
        s = s[:amp]
    return s + "…"


def split_message(text: str, limit: int = MAX_LEN) -> list[str]:
    """Режет длинный текст по строкам (строки сами по себе не содержат незакрытых тегов)."""
    parts, current = [], ""
    for line in text.split("\n"):
        if len(current) + len(line) + 1 > limit and current:
            parts.append(current)
            current = ""
        current = f"{current}\n{line}" if current else line
    if current:
        parts.append(current)
    return parts


def job_line(job: sqlite3.Row, tz: ZoneInfo, with_company: bool = False) -> str:
    """Одна строка о задании для списков."""
    state = job_state(job)
    name = escape(job["name"])
    if with_company:
        name = f"{escape(job['company_name'])} · {name}"
    finished = from_iso(job["last_finished"])
    if state == "missed" and finished:
        age = fmt_age(utcnow() - finished)
        return f"{ICON[state]} <b>{name}</b> — нет отчёта {age} (ожидается {fmt_interval(job['interval_hours'])})"
    if state == "paused":
        return f"{ICON[state]} <b>{name}</b> — на паузе"
    age = fmt_ago(utcnow() - finished) if finished else "—"
    line = f"{ICON[state]} <b>{name}</b> — {fmt_dt(finished, tz)} ({age}), {fmt_size(job['last_size'])}"
    if state in ("warning", "error"):
        hint = (job["last_notes"] or job["last_message"] or "").strip().splitlines()
        if hint:
            line += f"\n      <i>{escape_trunc(hint[0], 120)}</i>"
    return line


# ---------- уведомления ----------
def run_notification(company: str, job: sqlite3.Row, run: sqlite3.Row, prev_state: str | None,
                     is_latest: bool, tz: ZoneInfo) -> str:
    status = run["status"]
    finished = from_iso(run["finished"])
    lines = [f"{ICON[status]} <b>{escape(company)}</b> · {escape(job['name'])} — {STATUS_TEXT[status]}"]
    if prev_state is None:
        lines.append("🆕 новое задание зарегистрировано")

    info = [f"🖥 {escape(job['host'] or '—')}", f"🕑 {fmt_dt(finished, tz)}"]
    if run["duration_sec"] is not None:
        info.append(f"⏱ {fmt_duration(run['duration_sec'])}")
    if run["method"] == "vss":
        info.append("📸 снимок VSS")
    lines.append(" · ".join(info))

    info = []
    if run["size_bytes"] is not None:
        info.append(f"📦 {fmt_size(run['size_bytes'])}")
    if run["files"]:
        info.append(f"📄 файлов: {run['files']}")
    if run["free_bytes"] is not None:
        info.append(f"💽 свободно {fmt_size(run['free_bytes'])}")
    if info:
        lines.append(" · ".join(info))

    if run["exit_code"]:
        lines.append(f"Код выхода: {run['exit_code']}")
    if run["notes"]:
        lines.append(f"⚠️ {escape(run['notes'])}")
    if run["message"] and run["message"].strip():
        limit = 1500 if status != "ok" else 300
        lines.append(f"<pre>{escape_trunc(run['message'].strip(), limit)}</pre>")

    if prev_state in ("warning", "error", "missed") and status == "ok" and is_latest:
        lines.append(f"↩️ восстановлено (было: {STATUS_TEXT[prev_state]})")
    received = from_iso(run["received_at"])
    if received and finished and received - finished > timedelta(hours=1):
        lines.append(f"📨 отчёт доставлен с опозданием на {fmt_age(received - finished)}")
    if not is_latest:
        lines.append("ℹ️ это старый отчёт, текущее состояние задания не изменено")
    return "\n".join(lines)


def missed_notification(job: sqlite3.Row, tz: ZoneInfo, reminder: bool) -> str:
    finished = from_iso(job["last_finished"])
    age = fmt_age(utcnow() - finished) if finished else "—"
    head = "⏰ <b>Напоминание:</b> бекап всё ещё не приходит" if reminder else "⏰ <b>Бекап не пришёл вовремя</b>"
    return (
        f"{head}\n"
        f"<b>{escape(job['company_name'])}</b> · {escape(job['name'])} ({escape(job['host'] or '—')})\n"
        f"Последний отчёт: {fmt_dt(finished, tz)} ({age} назад)\n"
        f"Ожидается {fmt_interval(job['interval_hours'])}"
    )


# ---------- экраны бота ----------
def summary_view(db: DB, tz: ZoneInfo, title: str = "Сводка") -> tuple[str, InlineKeyboardMarkup]:
    companies = db.list_companies()
    jobs = db.all_jobs()
    counts = {k: 0 for k in ICON}
    by_company: dict[int, list[sqlite3.Row]] = {}
    for j in jobs:
        counts[job_state(j)] += 1
        by_company.setdefault(j["company_id"], []).append(j)

    now = datetime.now(tz).strftime("%d.%m %H:%M")
    lines = [f"📊 <b>{title}</b> · {now}"]
    if not companies:
        lines.append("\nКомпаний пока нет. Добавьте: /add_company Название")
    else:
        lines.append("  ".join(f"{ICON[k]} {counts[k]}" for k in ("ok", "warning", "error", "missed", "paused")
                               if counts[k] or k == "ok"))
        lines.append("")
        for c in companies:
            cj = by_company.get(c["id"], [])
            active = [j for j in cj if not j["paused"]]
            ok = sum(1 for j in active if j["state"] == "ok")
            worst = max((job_state(j) for j in cj), key=lambda s: SEVERITY[s], default="ok")
            if not cj:
                lines.append(f"🏢 <b>{escape(c['name'])}</b> — заданий нет")
                continue
            lines.append(f"🏢 <b>{escape(c['name'])}</b> — {ICON[worst]} {ok}/{len(active)}")
            for j in cj:
                if job_state(j) in ("warning", "error", "missed"):
                    lines.append("   " + job_line(j, tz))

    kb = InlineKeyboardBuilder()
    kb.button(text="🔄 Обновить", callback_data="sum")
    kb.button(text="🏢 Компании", callback_data="cl")
    return "\n".join(lines), kb.as_markup()


def problems_view(db: DB, tz: ZoneInfo) -> tuple[str, InlineKeyboardMarkup]:
    jobs = [j for j in db.all_jobs() if job_state(j) in ("warning", "error", "missed")]
    jobs.sort(key=lambda j: -SEVERITY[job_state(j)])
    kb = InlineKeyboardBuilder()
    if not jobs:
        text = "✅ <b>Проблем нет</b>\nВсе бекапы в порядке."
    else:
        text = f"⚠️ <b>Проблемы: {len(jobs)}</b>\n\n" + "\n".join(job_line(j, tz, with_company=True) for j in jobs)
        for j in jobs[:30]:
            kb.button(text=f"{ICON[job_state(j)]} {j['company_name']} · {j['name']}"[:60], callback_data=f"j:{j['id']}")
    kb.button(text="🔄 Обновить", callback_data="pr")
    kb.adjust(1)
    return text, kb.as_markup()


def companies_view(db: DB) -> tuple[str, InlineKeyboardMarkup]:
    companies = db.list_companies()
    jobs = db.all_jobs()
    kb = InlineKeyboardBuilder()
    if not companies:
        return "Компаний пока нет.\nДобавьте: <code>/add_company Название</code>", kb.as_markup()
    for c in companies:
        cj = [j for j in jobs if j["company_id"] == c["id"]]
        worst = max((job_state(j) for j in cj), key=lambda s: SEVERITY[s], default="ok")
        icon = ICON[worst] if cj else "▫️"
        kb.button(text=f"{icon} {c['name']} ({len(cj)})"[:60], callback_data=f"c:{c['id']}")
    kb.adjust(1)
    return "🏢 <b>Компании</b>\nВыберите компанию:", kb.as_markup()


def company_view(db: DB, company_id: int, tz: ZoneInfo) -> tuple[str, InlineKeyboardMarkup]:
    c = db.get_company(company_id)
    kb = InlineKeyboardBuilder()
    if c is None:
        kb.button(text="⬅️ К списку", callback_data="cl")
        return "Компания не найдена (удалена?)", kb.as_markup()
    jobs = db.jobs_for_company(company_id)
    lines = [f"🏢 <b>{escape(c['name'])}</b>", ""]
    if not jobs:
        lines.append("Отчётов пока не было. Задания появятся сами после первого отчёта агента.")
    lines += [job_line(j, tz) for j in jobs]
    for j in jobs:
        kb.button(text=f"{ICON[job_state(j)]} {j['name']}"[:60], callback_data=f"j:{j['id']}")
    kb.button(text="🔄 Обновить", callback_data=f"c:{company_id}")
    kb.button(text="🔑 Токен", callback_data=f"ct:{company_id}")
    kb.button(text="🗑 Удалить компанию", callback_data=f"cd:{company_id}")
    kb.button(text="⬅️ К списку", callback_data="cl")
    kb.adjust(*([1] * len(jobs)), 2, 2)
    return "\n".join(lines), kb.as_markup()


def job_view(db: DB, job_id: int, tz: ZoneInfo) -> tuple[str, InlineKeyboardMarkup]:
    j = db.get_job(job_id)
    kb = InlineKeyboardBuilder()
    if j is None:
        kb.button(text="⬅️ К компаниям", callback_data="cl")
        return "Задание не найдено (удалено?)", kb.as_markup()
    state = job_state(j)
    finished = from_iso(j["last_finished"])
    age = f" ({fmt_ago(utcnow() - finished)})" if finished else ""
    last_status = STATUS_TEXT.get(j["last_status"] or "", "—")
    lines = [
        f"{ICON[state]} <b>{escape(j['company_name'])} · {escape(j['name'])}</b>",
        f"🖥 Хост: {escape(j['host'] or '—')}",
        f"🔁 Периодичность: {fmt_interval(j['interval_hours'])}",
        f"🕑 Последний: {fmt_dt(finished, tz)}{age} — {last_status}",
        f"📦 Размер: {fmt_size(j['last_size'])} · 💽 свободно: {fmt_size(j['last_free'])}",
    ]
    if j["last_archive"]:
        lines.append(f"📁 <code>{escape_trunc(j['last_archive'], 200)}</code>")
    if j["paused"]:
        lines.append("⏸ <b>На паузе</b> — пропуски не отслеживаются")
    elif state == "missed":
        lines.append(f"⏰ <b>Нет отчёта дольше ожидаемого</b>")
    if j["last_notes"]:
        lines.append(f"⚠️ {escape(j['last_notes'])}")

    runs = db.recent_runs(job_id, 10)
    if runs:
        lines += ["", "<b>Последние запуски:</b>"]
        for r in runs:
            parts = [f"{ICON[r['status']]} {fmt_dt(from_iso(r['finished']), tz)}", fmt_size(r["size_bytes"])]
            if r["duration_sec"] is not None:
                parts.append(fmt_duration(r["duration_sec"]))
            if r["exit_code"]:
                parts.append(f"код {r['exit_code']}")
            lines.append(" · ".join(parts))

    kb.button(text="📜 Вывод последнего запуска", callback_data=f"jl:{job_id}")
    kb.button(text="▶️ Снять с паузы" if j["paused"] else "⏸ Пауза", callback_data=f"jp:{job_id}")
    kb.button(text="🗑 Удалить", callback_data=f"jd:{job_id}")
    kb.button(text="🔄 Обновить", callback_data=f"j:{job_id}")
    kb.button(text="⬅️ К компании", callback_data=f"c:{j['company_id']}")
    kb.adjust(1, 2, 2)
    return "\n".join(lines), kb.as_markup()


def job_log_view(db: DB, job_id: int, tz: ZoneInfo) -> tuple[str, InlineKeyboardMarkup]:
    j = db.get_job(job_id)
    kb = InlineKeyboardBuilder()
    kb.button(text="⬅️ Назад", callback_data=f"j:{job_id}")
    if j is None:
        return "Задание не найдено", kb.as_markup()
    msg = (j["last_message"] or "").strip() or "(агент не прислал вывода)"
    head = (f"📜 <b>{escape(j['company_name'])} · {escape(j['name'])}</b>\n"
            f"{fmt_dt(from_iso(j['last_finished']), tz)}, код выхода: {j['last_exit_code']}\n")
    # лимит считаем от длины заголовка, чтобы весь экран влез в одно сообщение и <pre> не разрезался
    body = escape_trunc(msg, MAX_LEN - 100 - len(head))
    return head + f"<pre>{body}</pre>", kb.as_markup()


def confirm_kb(yes_data: str, no_data: str) -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="✅ Да, удалить", callback_data=yes_data)
    kb.button(text="Отмена", callback_data=no_data)
    return kb.as_markup()
