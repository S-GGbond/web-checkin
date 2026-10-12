"""统一账号存储：WorkBuddy 与 Trae 共用同一个 SQLite 数据库。"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from typing import Any, Iterable


DEFAULT_HUB_DB = "checkin-hub.sqlite3"


class AccountStore:
    def __init__(self, db_path: str = DEFAULT_HUB_DB):
        self.db_path = db_path
        self._conn = sqlite3.connect(self.db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.execute("PRAGMA busy_timeout = 5000")
        self._init_schema()
        try:
            os.chmod(self.db_path, 0o600)
        except OSError:
            pass

    def _init_schema(self) -> None:
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                provider TEXT NOT NULL,
                external_id TEXT NOT NULL,
                display_name TEXT NOT NULL DEFAULT '',
                label TEXT NOT NULL DEFAULT '',
                endpoint TEXT NOT NULL,
                credential TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                last_status TEXT,
                last_status_at INTEGER,
                last_checkin_at INTEGER,
                last_checkin_ok INTEGER,
                last_checkin_message TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(provider, external_id)
            );

            CREATE TABLE IF NOT EXISTS checkin_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER NOT NULL,
                provider TEXT NOT NULL,
                action TEXT NOT NULL,
                ok INTEGER NOT NULL,
                code INTEGER,
                message TEXT,
                payload_json TEXT,
                created_at INTEGER NOT NULL,
                FOREIGN KEY(account_id) REFERENCES accounts(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_checkin_logs_account_time
                ON checkin_logs(account_id, created_at);
            """
        )
        columns = {row[1] for row in self._conn.execute("PRAGMA table_info(accounts)").fetchall()}
        if "schedule_time" not in columns:
            self._conn.execute("ALTER TABLE accounts ADD COLUMN schedule_time TEXT NOT NULL DEFAULT '09:00'")
        if "schedule_enabled" not in columns:
            self._conn.execute("ALTER TABLE accounts ADD COLUMN schedule_enabled INTEGER NOT NULL DEFAULT 1")
        if "schedule_last_date" not in columns:
            self._conn.execute("ALTER TABLE accounts ADD COLUMN schedule_last_date TEXT")
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    @staticmethod
    def _public_account(row: sqlite3.Row) -> dict[str, Any]:
        data = dict(row)
        data.pop("credential", None)
        data["enabled"] = bool(data.get("enabled"))
        data["schedule_enabled"] = bool(data.get("schedule_enabled"))
        try:
            data["last_status"] = json.loads(data["last_status"]) if data.get("last_status") else None
        except Exception:
            data["last_status"] = None
        return data

    def upsert_account(
        self,
        *,
        provider: str,
        external_id: str,
        display_name: str,
        endpoint: str,
        credential: str,
        label: str = "",
    ) -> int:
        timestamp = int(time.time())
        self._conn.execute(
            """
            INSERT INTO accounts (
                provider, external_id, display_name, label, endpoint, credential,
                enabled, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(provider, external_id) DO UPDATE SET
                display_name = CASE WHEN excluded.display_name = '' THEN accounts.display_name ELSE excluded.display_name END,
                label = CASE WHEN excluded.label = '' THEN accounts.label ELSE excluded.label END,
                endpoint = excluded.endpoint,
                credential = excluded.credential,
                enabled = 1,
                updated_at = excluded.updated_at
            """,
            (provider, external_id, display_name, label, endpoint, credential, timestamp, timestamp),
        )
        self._conn.commit()
        row = self._conn.execute(
            "SELECT id FROM accounts WHERE provider = ? AND external_id = ?",
            (provider, external_id),
        ).fetchone()
        return int(row["id"])

    def list_accounts(self, provider: str | None = None, enabled_only: bool = False) -> list[dict[str, Any]]:
        sql = "SELECT * FROM accounts"
        conditions: list[str] = []
        params: list[Any] = []
        if provider:
            conditions.append("provider = ?")
            params.append(provider)
        if enabled_only:
            conditions.append("enabled = 1")
        if conditions:
            sql += " WHERE " + " AND ".join(conditions)
        sql += " ORDER BY CASE provider WHEN 'workbuddy' THEN 0 WHEN 'trae' THEN 1 ELSE 2 END, created_at, id"
        return [self._public_account(row) for row in self._conn.execute(sql, params).fetchall()]

    def list_account_rows(self, enabled_only: bool = False) -> list[sqlite3.Row]:
        """仅供后端平台调用使用，返回包含凭据的内部账号记录。"""
        sql = "SELECT * FROM accounts"
        if enabled_only:
            sql += " WHERE enabled = 1"
        sql += " ORDER BY CASE provider WHEN 'workbuddy' THEN 0 WHEN 'trae' THEN 1 ELSE 2 END, created_at, id"
        return self._conn.execute(sql).fetchall()

    def get_account(self, account_id: int) -> sqlite3.Row | None:
        return self._conn.execute("SELECT * FROM accounts WHERE id = ?", (account_id,)).fetchone()

    def set_enabled(self, account_id: int, enabled: bool) -> bool:
        cursor = self._conn.execute(
            "UPDATE accounts SET enabled = ?, updated_at = ? WHERE id = ?",
            (int(enabled), int(time.time()), account_id),
        )
        self._conn.commit()
        return cursor.rowcount == 1

    def update_schedule(self, account_id: int, *, enabled: bool, schedule_time: str) -> bool:
        cursor = self._conn.execute(
            """
            UPDATE accounts
            SET schedule_enabled = ?, schedule_time = ?, updated_at = ?
            WHERE id = ?
            """,
            (int(enabled), schedule_time, int(time.time()), account_id),
        )
        self._conn.commit()
        return cursor.rowcount == 1

    def mark_schedule_run(self, account_id: int, run_date: str) -> None:
        self._conn.execute(
            "UPDATE accounts SET schedule_last_date = ?, updated_at = ? WHERE id = ?",
            (run_date, int(time.time()), account_id),
        )
        self._conn.commit()

    def delete_account(self, account_id: int) -> bool:
        cursor = self._conn.execute("DELETE FROM accounts WHERE id = ?", (account_id,))
        self._conn.commit()
        return cursor.rowcount == 1

    def update_account(self, account_id: int, *, credential: str, display_name: str | None = None) -> None:
        self._conn.execute(
            "UPDATE accounts SET credential = ?, display_name = COALESCE(?, display_name), updated_at = ? WHERE id = ?",
            (credential, display_name, int(time.time()), account_id),
        )
        self._conn.commit()

    def update_status(self, account_id: int, status: dict[str, Any] | None) -> None:
        self._conn.execute(
            "UPDATE accounts SET last_status = ?, last_status_at = ?, updated_at = ? WHERE id = ?",
            (
                json.dumps(status, ensure_ascii=False, sort_keys=True) if status is not None else None,
                int(time.time()),
                int(time.time()),
                account_id,
            ),
        )
        self._conn.commit()

    def update_checkin(self, account_id: int, *, ok: bool, message: str) -> None:
        self._conn.execute(
            """
            UPDATE accounts
            SET last_checkin_at = ?, last_checkin_ok = ?, last_checkin_message = ?, updated_at = ?
            WHERE id = ?
            """,
            (int(time.time()), int(ok), message[:500], int(time.time()), account_id),
        )
        self._conn.commit()

    def add_log(
        self,
        account_id: int,
        provider: str,
        *,
        action: str,
        ok: bool,
        code: int | None = None,
        message: str = "",
        payload: Any = None,
    ) -> None:
        self._conn.execute(
            """
            INSERT INTO checkin_logs
                (account_id, provider, action, ok, code, message, payload_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                account_id,
                provider,
                action,
                int(ok),
                code,
                message[:500],
                json.dumps(payload, ensure_ascii=False, sort_keys=True) if payload is not None else None,
                int(time.time()),
            ),
        )
        self._conn.commit()

    def recent_logs(self, limit: int = 80) -> list[dict[str, Any]]:
        rows = self._conn.execute(
            """
            SELECT l.id, l.account_id, a.display_name, a.label, l.provider, l.action,
                   l.ok, l.code, l.message, l.created_at
            FROM checkin_logs l
            LEFT JOIN accounts a ON a.id = l.account_id
            ORDER BY l.id DESC LIMIT ?
            """,
            (max(1, min(limit, 500)),),
        ).fetchall()
        result = []
        for row in rows:
            data = dict(row)
            data["ok"] = bool(data["ok"])
            result.append(data)
        return result

    def get_setting(self, key: str, default: str | None = None) -> str | None:
        row = self._conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default

    def set_setting(self, key: str, value: str) -> None:
        self._conn.execute(
            "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )
        self._conn.commit()

    def all_settings(self) -> dict[str, str]:
        return {row["key"]: row["value"] for row in self._conn.execute("SELECT key, value FROM settings")}
