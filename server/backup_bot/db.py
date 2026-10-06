"""Хранилище на SQLite. Все времена хранятся в UTC в формате ISO."""
from __future__ import annotations

import secrets
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from statistics import median

SCHEMA = """
CREATE TABLE IF NOT EXISTS companies (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    token       TEXT NOT NULL UNIQUE,
    created_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS jobs (
    id                  INTEGER PRIMARY KEY,
    company_id          INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,
    host                TEXT,
    interval_hours      REAL NOT NULL DEFAULT 24,
    state               TEXT NOT NULL DEFAULT 'ok',
    paused              INTEGER NOT NULL DEFAULT 0,
    last_finished       TEXT,
    last_run_id         INTEGER,
    missed_notified_at  TEXT,
    created_at          TEXT NOT NULL,
    UNIQUE (company_id, name)
);
CREATE TABLE IF NOT EXISTS runs (
    id            INTEGER PRIMARY KEY,
    run_uid       TEXT UNIQUE,
    job_id        INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    status        TEXT NOT NULL,
    exit_code     INTEGER,
    started       TEXT,
    finished      TEXT NOT NULL,
    duration_sec  REAL,
    size_bytes    INTEGER,
    files         INTEGER,
    free_bytes    INTEGER,
    archive       TEXT,
    message       TEXT,
    notes         TEXT,
    received_at   TEXT NOT NULL,
    method        TEXT
);
CREATE INDEX IF NOT EXISTS runs_job_finished ON runs (job_id, finished DESC);
-- исходящие сообщения в Telegram: лежат здесь, пока не доставлены (переживают сбой сети и рестарт)
CREATE TABLE IF NOT EXISTS outbox (
    id          INTEGER PRIMARY KEY,
    chat_id     INTEGER NOT NULL,
    text        TEXT NOT NULL,
    silent      INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL
);
"""


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def to_iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def from_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value)


@dataclass
class RunReport:
    """Отчёт агента после разбора и проверки."""
    run_uid: str
    job: str
    host: str | None
    status: str
    exit_code: int | None
    started: datetime | None
    finished: datetime
    duration_sec: float | None
    size_bytes: int | None
    files: int | None
    free_bytes: int | None
    archive: str | None
    interval_hours: float
    message: str | None
    notes: str | None = None
    method: str | None = None   # vss — архив сделан со снимка тома


@dataclass
class RecordResult:
    job: sqlite3.Row
    run: sqlite3.Row
    prev_state: str | None   # None, если задание новое
    is_latest: bool          # False, если пришёл запоздавший старый отчёт


class DB:
    def __init__(self, path: Path | str):
        self.conn = sqlite3.connect(str(path), check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.executescript(SCHEMA)
        self._migrate()

    def _migrate(self) -> None:
        # базы, созданные до появления колонки method
        cols = {r["name"] for r in self.conn.execute("PRAGMA table_info(runs)")}
        if "method" not in cols:
            with self.conn:
                self.conn.execute("ALTER TABLE runs ADD COLUMN method TEXT")

    # ---------- компании ----------
    def add_company(self, name: str) -> str:
        token = secrets.token_urlsafe(24)
        with self.conn:
            self.conn.execute(
                "INSERT INTO companies(name, token, created_at) VALUES (?,?,?)",
                (name, token, to_iso(utcnow())),
            )
        return token

    def company_by_token(self, token: str) -> sqlite3.Row | None:
        if not token:
            return None
        return self.conn.execute("SELECT * FROM companies WHERE token=?", (token,)).fetchone()

    def get_company(self, company_id: int) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM companies WHERE id=?", (company_id,)).fetchone()

    def list_companies(self) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM companies ORDER BY name COLLATE NOCASE").fetchall()

    def rename_company(self, company_id: int, name: str) -> None:
        with self.conn:
            self.conn.execute("UPDATE companies SET name=? WHERE id=?", (name, company_id))

    def regenerate_token(self, company_id: int) -> str:
        token = secrets.token_urlsafe(24)
        with self.conn:
            self.conn.execute("UPDATE companies SET token=? WHERE id=?", (token, company_id))
        return token

    def delete_company(self, company_id: int) -> None:
        with self.conn:
            self.conn.execute("DELETE FROM companies WHERE id=?", (company_id,))

    # ---------- задания ----------
    _JOB_SELECT = """
        SELECT j.*, c.name AS company_name,
               r.status AS last_status, r.size_bytes AS last_size, r.free_bytes AS last_free,
               r.message AS last_message, r.notes AS last_notes, r.archive AS last_archive,
               r.exit_code AS last_exit_code, r.duration_sec AS last_duration, r.files AS last_files
        FROM jobs j
        JOIN companies c ON c.id = j.company_id
        LEFT JOIN runs r ON r.id = j.last_run_id
    """

    def get_job(self, job_id: int) -> sqlite3.Row | None:
        return self.conn.execute(self._JOB_SELECT + " WHERE j.id=?", (job_id,)).fetchone()

    def jobs_for_company(self, company_id: int) -> list[sqlite3.Row]:
        return self.conn.execute(
            self._JOB_SELECT + " WHERE j.company_id=? ORDER BY j.name COLLATE NOCASE", (company_id,)
        ).fetchall()

    def all_jobs(self) -> list[sqlite3.Row]:
        return self.conn.execute(
            self._JOB_SELECT + " ORDER BY c.name COLLATE NOCASE, j.name COLLATE NOCASE"
        ).fetchall()

    def set_job_state(self, job_id: int, state: str, missed_notified_at: datetime | None) -> None:
        with self.conn:
            self.conn.execute(
                "UPDATE jobs SET state=?, missed_notified_at=? WHERE id=?",
                (state, to_iso(missed_notified_at) if missed_notified_at else None, job_id),
            )

    def toggle_pause(self, job_id: int) -> bool:
        with self.conn:
            self.conn.execute("UPDATE jobs SET paused = 1 - paused WHERE id=?", (job_id,))
        row = self.conn.execute("SELECT paused FROM jobs WHERE id=?", (job_id,)).fetchone()
        return bool(row and row["paused"])

    def delete_job(self, job_id: int) -> None:
        with self.conn:
            self.conn.execute("DELETE FROM jobs WHERE id=?", (job_id,))

    # ---------- запуски ----------
    def recent_runs(self, job_id: int, limit: int = 10) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM runs WHERE job_id=? ORDER BY finished DESC LIMIT ?", (job_id, limit)
        ).fetchall()

    def typical_size(self, company_id: int, job_name: str, sample: int = 5) -> int | None:
        """Медиана размера последних успешных архивов задания."""
        rows = self.conn.execute(
            """SELECT r.size_bytes FROM runs r JOIN jobs j ON j.id = r.job_id
               WHERE j.company_id=? AND j.name=? AND r.status='ok' AND r.size_bytes > 0
               ORDER BY r.finished DESC LIMIT ?""",
            (company_id, job_name, sample),
        ).fetchall()
        if len(rows) < 2:
            return None
        return int(median(r["size_bytes"] for r in rows))

    def run_exists(self, run_uid: str) -> bool:
        return self.conn.execute("SELECT 1 FROM runs WHERE run_uid=?", (run_uid,)).fetchone() is not None

    def record_run(self, company_id: int, rep: RunReport) -> RecordResult | None:
        """Сохраняет запуск. Возвращает None, если такой отчёт уже был (повторная доставка)."""
        now = utcnow()
        with self.conn:
            job = self.conn.execute(
                "SELECT * FROM jobs WHERE company_id=? AND name=?", (company_id, rep.job)
            ).fetchone()
            if job is None:
                cur = self.conn.execute(
                    "INSERT INTO jobs(company_id, name, host, interval_hours, state, created_at) "
                    "VALUES (?,?,?,?,?,?)",
                    (company_id, rep.job, rep.host, rep.interval_hours, rep.status, to_iso(now)),
                )
                job_id, prev_state, last_finished = cur.lastrowid, None, None
            else:
                job_id, prev_state, last_finished = job["id"], job["state"], from_iso(job["last_finished"])

            try:
                cur = self.conn.execute(
                    """INSERT INTO runs(run_uid, job_id, status, exit_code, started, finished, duration_sec,
                                        size_bytes, files, free_bytes, archive, message, notes, received_at, method)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (rep.run_uid, job_id, rep.status, rep.exit_code,
                     to_iso(rep.started) if rep.started else None, to_iso(rep.finished),
                     rep.duration_sec, rep.size_bytes, rep.files, rep.free_bytes, rep.archive,
                     rep.message, rep.notes, to_iso(now), rep.method),
                )
            except sqlite3.IntegrityError:
                return None
            run_id = cur.lastrowid

            is_latest = last_finished is None or rep.finished >= last_finished
            if is_latest:
                self.conn.execute(
                    """UPDATE jobs SET host=?, interval_hours=?, state=?, last_finished=?, last_run_id=?,
                                       missed_notified_at=NULL WHERE id=?""",
                    (rep.host, rep.interval_hours, rep.status, to_iso(rep.finished), run_id, job_id),
                )

        return RecordResult(
            job=self.get_job(job_id),
            run=self.conn.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone(),
            prev_state=prev_state,
            is_latest=is_latest,
        )

    # ---------- очередь сообщений ----------
    def outbox_add(self, chat_id: int, text: str, silent: bool) -> None:
        with self.conn:
            self.conn.execute(
                "INSERT INTO outbox(chat_id, text, silent, created_at) VALUES (?,?,?,?)",
                (chat_id, text, int(silent), to_iso(utcnow())),
            )

    def outbox_next(self) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM outbox ORDER BY id LIMIT 1").fetchone()

    def outbox_delete(self, msg_id: int) -> None:
        with self.conn:
            self.conn.execute("DELETE FROM outbox WHERE id=?", (msg_id,))

    def outbox_size(self) -> int:
        return self.conn.execute("SELECT COUNT(*) FROM outbox").fetchone()[0]

    def prune_runs(self, keep_days: int) -> int:
        border = to_iso(utcnow() - timedelta(days=keep_days))
        with self.conn:
            cur = self.conn.execute(
                "DELETE FROM runs WHERE finished < ? AND id NOT IN "
                "(SELECT last_run_id FROM jobs WHERE last_run_id IS NOT NULL)",
                (border,),
            )
        return cur.rowcount
