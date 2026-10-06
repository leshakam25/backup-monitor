"""Настройки сервера. Читаются из переменных окружения или файла .env."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo


def _load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def _ids(value: str) -> frozenset[int]:
    return frozenset(int(x) for x in value.replace(";", ",").split(",") if x.strip())


def _bool(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes", "on", "да")


@dataclass(frozen=True)
class Config:
    bot_token: str
    admin_ids: frozenset[int]          # кто может пользоваться ботом
    notify_chat_ids: frozenset[int]    # куда слать уведомления (по умолчанию = admin_ids)
    listen_host: str
    listen_port: int
    db_path: Path
    tz: ZoneInfo
    summary_time: tuple[int, int] | None
    notify_success: bool
    success_silent: bool
    grace_factor: float
    grace_minutes: float
    missed_repeat_hours: float
    size_drop_ratio: float
    runs_keep_days: int
    ssl_cert: str | None
    ssl_key: str | None
    telegram_proxy: str | None   # http://amnezia:8888 — ходить в Telegram через VPN-контейнер


def load_config() -> Config:
    _load_env_file(Path(os.environ.get("BACKUP_BOT_ENV", ".env")))
    env = os.environ.get

    token = env("BOT_TOKEN", "").strip()
    if not token:
        raise SystemExit("BOT_TOKEN не задан (см. .env.example)")

    admins = _ids(env("ADMIN_IDS", ""))
    notify = _ids(env("NOTIFY_CHAT_IDS", "")) or admins

    summary_raw = env("SUMMARY_TIME", "09:00").strip()
    summary = None
    if summary_raw and summary_raw.lower() not in ("off", "no", "0"):
        h, m = summary_raw.split(":")
        summary = (int(h), int(m))

    return Config(
        bot_token=token,
        admin_ids=admins,
        notify_chat_ids=notify,
        listen_host=env("LISTEN_HOST", "127.0.0.1"),
        listen_port=int(env("LISTEN_PORT", "8080")),
        db_path=Path(env("DB_PATH", "backup_bot.sqlite3")),
        tz=ZoneInfo(env("TZ_NAME", "Europe/Moscow")),
        summary_time=summary,
        notify_success=_bool(env("NOTIFY_SUCCESS", "true")),
        success_silent=_bool(env("SUCCESS_SILENT", "true")),
        grace_factor=float(env("GRACE_FACTOR", "1.25")),
        grace_minutes=float(env("GRACE_MINUTES", "15")),
        missed_repeat_hours=float(env("MISSED_REPEAT_HOURS", "24")),
        size_drop_ratio=float(env("SIZE_DROP_RATIO", "0.5")),
        runs_keep_days=int(env("RUNS_KEEP_DAYS", "365")),
        ssl_cert=env("SSL_CERT") or None,
        ssl_key=env("SSL_KEY") or None,
        telegram_proxy=(env("TELEGRAM_PROXY") or "").strip() or None,
    )
