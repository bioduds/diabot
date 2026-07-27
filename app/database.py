from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "cgm_assistant.db"


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with get_connection() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS user_profile (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                name TEXT,
                glucose_unit TEXT NOT NULL DEFAULT 'mg/dL',
                basal_insulin TEXT,
                basal_units REAL,
                basal_schedule TEXT,
                bolus_insulin TEXT,
                insulin_to_carb_ratio REAL,
                correction_factor REAL,
                target_glucose_low REAL,
                target_glucose_high REAL,
                weight_unit TEXT NOT NULL DEFAULT 'kg',
                libre_device TEXT DEFAULT 'FreeStyle Libre 2 Plus',
                disclaimer_accepted INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS glucose_readings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL DEFAULT 'mg/dL',
                source TEXT NOT NULL DEFAULT 'librelink',
                trend TEXT,
                created_at TEXT NOT NULL,
                UNIQUE(timestamp, source)
            );

            CREATE TABLE IF NOT EXISTS carb_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                carbs_grams REAL NOT NULL,
                meal_description TEXT,
                bolus_units REAL,
                notes TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS exercise_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                activity_type TEXT NOT NULL,
                duration_minutes INTEGER,
                intensity TEXT,
                notes TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS weight_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                weight REAL NOT NULL,
                unit TEXT NOT NULL DEFAULT 'kg',
                notes TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS insulin_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                insulin_type TEXT NOT NULL,
                units REAL NOT NULL,
                reason TEXT,
                notes TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS chat_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS checkin_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                last_carb_prompt TEXT,
                last_exercise_prompt TEXT,
                last_weight_prompt TEXT,
                last_glucose_review TEXT,
                last_insulin_prompt TEXT,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS librelinkup_account (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                email TEXT NOT NULL,
                password_encrypted TEXT NOT NULL,
                api_region TEXT NOT NULL DEFAULT 'LA',
                patient_id TEXT,
                patient_name TEXT,
                connected INTEGER NOT NULL DEFAULT 0,
                last_sync_at TEXT,
                last_sync_status TEXT,
                last_error TEXT,
                auto_sync_minutes INTEGER NOT NULL DEFAULT 5,
                updated_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_glucose_timestamp ON glucose_readings(timestamp);
            CREATE INDEX IF NOT EXISTS idx_carb_timestamp ON carb_logs(timestamp);
            CREATE INDEX IF NOT EXISTS idx_exercise_timestamp ON exercise_logs(timestamp);
            CREATE INDEX IF NOT EXISTS idx_weight_timestamp ON weight_logs(timestamp);
            """
        )
        conn.execute(
            """
            INSERT OR IGNORE INTO checkin_state (id, updated_at)
            VALUES (1, ?)
            """,
            (_utcnow(),),
        )


@contextmanager
def get_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def get_profile() -> dict[str, Any] | None:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM user_profile WHERE id = 1").fetchone()
        return dict(row) if row else None


def save_profile(data: dict[str, Any]) -> dict[str, Any]:
    now = _utcnow()
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO user_profile (
                id, name, glucose_unit, basal_insulin, basal_units, basal_schedule,
                bolus_insulin, insulin_to_carb_ratio, correction_factor,
                target_glucose_low, target_glucose_high, weight_unit,
                libre_device, disclaimer_accepted, updated_at
            ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                glucose_unit = excluded.glucose_unit,
                basal_insulin = excluded.basal_insulin,
                basal_units = excluded.basal_units,
                basal_schedule = excluded.basal_schedule,
                bolus_insulin = excluded.bolus_insulin,
                insulin_to_carb_ratio = excluded.insulin_to_carb_ratio,
                correction_factor = excluded.correction_factor,
                target_glucose_low = excluded.target_glucose_low,
                target_glucose_high = excluded.target_glucose_high,
                weight_unit = excluded.weight_unit,
                libre_device = excluded.libre_device,
                disclaimer_accepted = excluded.disclaimer_accepted,
                updated_at = excluded.updated_at
            """,
            (
                data.get("name"),
                data.get("glucose_unit", "mg/dL"),
                data.get("basal_insulin"),
                data.get("basal_units"),
                json.dumps(data.get("basal_schedule")) if data.get("basal_schedule") else None,
                data.get("bolus_insulin"),
                data.get("insulin_to_carb_ratio"),
                data.get("correction_factor"),
                data.get("target_glucose_low"),
                data.get("target_glucose_high"),
                data.get("weight_unit", "kg"),
                data.get("libre_device", "FreeStyle Libre 2 Plus"),
                1 if data.get("disclaimer_accepted") else 0,
                now,
            ),
        )
    return get_profile() or {}


def insert_glucose_readings(readings: list[dict[str, Any]]) -> int:
    now = _utcnow()
    inserted = 0
    with get_connection() as conn:
        for reading in readings:
            cursor = conn.execute(
                """
                INSERT OR IGNORE INTO glucose_readings
                (timestamp, value, unit, source, trend, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    reading["timestamp"],
                    reading["value"],
                    reading.get("unit", "mg/dL"),
                    reading.get("source", "librelink"),
                    reading.get("trend"),
                    now,
                ),
            )
            inserted += cursor.rowcount
    return inserted


def add_carb_log(data: dict[str, Any]) -> dict[str, Any]:
    now = _utcnow()
    with get_connection() as conn:
        cursor = conn.execute(
            """
            INSERT INTO carb_logs (timestamp, carbs_grams, meal_description, bolus_units, notes, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                data["timestamp"],
                data["carbs_grams"],
                data.get("meal_description"),
                data.get("bolus_units"),
                data.get("notes"),
                now,
            ),
        )
        row = conn.execute("SELECT * FROM carb_logs WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)


def add_exercise_log(data: dict[str, Any]) -> dict[str, Any]:
    now = _utcnow()
    with get_connection() as conn:
        cursor = conn.execute(
            """
            INSERT INTO exercise_logs (timestamp, activity_type, duration_minutes, intensity, notes, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                data["timestamp"],
                data["activity_type"],
                data.get("duration_minutes"),
                data.get("intensity"),
                data.get("notes"),
                now,
            ),
        )
        row = conn.execute("SELECT * FROM exercise_logs WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)


def add_weight_log(data: dict[str, Any]) -> dict[str, Any]:
    now = _utcnow()
    with get_connection() as conn:
        cursor = conn.execute(
            """
            INSERT INTO weight_logs (timestamp, weight, unit, notes, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                data["timestamp"],
                data["weight"],
                data.get("unit", "kg"),
                data.get("notes"),
                now,
            ),
        )
        row = conn.execute("SELECT * FROM weight_logs WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)


def add_insulin_log(data: dict[str, Any]) -> dict[str, Any]:
    now = _utcnow()
    with get_connection() as conn:
        cursor = conn.execute(
            """
            INSERT INTO insulin_logs (timestamp, insulin_type, units, reason, notes, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                data["timestamp"],
                data["insulin_type"],
                data["units"],
                data.get("reason"),
                data.get("notes"),
                now,
            ),
        )
        row = conn.execute("SELECT * FROM insulin_logs WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return dict(row)


def recent_rows(table: str, limit: int = 50) -> list[dict[str, Any]]:
    allowed = {
        "glucose_readings": "timestamp",
        "carb_logs": "timestamp",
        "exercise_logs": "timestamp",
        "weight_logs": "timestamp",
        "insulin_logs": "timestamp",
    }
    if table not in allowed:
        raise ValueError(f"Unsupported table: {table}")
    with get_connection() as conn:
        rows = conn.execute(
            f"SELECT * FROM {table} ORDER BY {allowed[table]} DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [dict(row) for row in rows]


def add_chat_message(role: str, content: str) -> None:
    with get_connection() as conn:
        conn.execute(
            "INSERT INTO chat_messages (role, content, created_at) VALUES (?, ?, ?)",
            (role, content, _utcnow()),
        )


def get_chat_history(limit: int = 30) -> list[dict[str, str]]:
    with get_connection() as conn:
        rows = conn.execute(
            "SELECT role, content FROM chat_messages ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [{"role": row["role"], "content": row["content"]} for row in reversed(rows)]


def get_checkin_state() -> dict[str, Any]:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM checkin_state WHERE id = 1").fetchone()
        return dict(row) if row else {}


def update_checkin_prompt(field: str, timestamp: str | None = None) -> None:
    allowed = {
        "last_carb_prompt",
        "last_exercise_prompt",
        "last_weight_prompt",
        "last_glucose_review",
        "last_insulin_prompt",
    }
    if field not in allowed:
        raise ValueError(f"Unsupported check-in field: {field}")
    with get_connection() as conn:
        conn.execute(
            f"UPDATE checkin_state SET {field} = ?, updated_at = ? WHERE id = 1",
            (timestamp or _utcnow(), _utcnow()),
        )


def latest_timestamp(table: str) -> str | None:
    allowed = {
        "carb_logs",
        "exercise_logs",
        "weight_logs",
        "insulin_logs",
        "glucose_readings",
    }
    if table not in allowed:
        raise ValueError(f"Unsupported table: {table}")
    with get_connection() as conn:
        row = conn.execute(f"SELECT MAX(timestamp) AS ts FROM {table}").fetchone()
        return row["ts"] if row and row["ts"] else None


def glucose_stats(hours: int = 24) -> dict[str, Any]:
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT value, unit, timestamp FROM glucose_readings
            WHERE timestamp >= datetime('now', ?)
            ORDER BY timestamp ASC
            """,
            (f"-{hours} hours",),
        ).fetchall()
    if not rows:
        return {"count": 0, "readings": []}
    values = [row["value"] for row in rows]
    unit = rows[0]["unit"]
    return {
        "count": len(values),
        "unit": unit,
        "average": round(sum(values) / len(values), 1),
        "min": min(values),
        "max": max(values),
        "latest": values[-1],
        "latest_timestamp": rows[-1]["timestamp"],
        "readings": [dict(row) for row in rows[-48:]],
    }


def get_librelinkup_account() -> dict[str, Any] | None:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM librelinkup_account WHERE id = 1").fetchone()
        if not row:
            return None
        data = dict(row)
        data.pop("password_encrypted", None)
        return data


def get_librelinkup_credentials() -> dict[str, Any] | None:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM librelinkup_account WHERE id = 1 AND connected = 1").fetchone()
        return dict(row) if row else None


def save_librelinkup_account(data: dict[str, Any]) -> dict[str, Any]:
    now = _utcnow()
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO librelinkup_account (
                id, email, password_encrypted, api_region, patient_id, patient_name,
                connected, last_sync_at, last_sync_status, last_error,
                auto_sync_minutes, updated_at
            ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                email = excluded.email,
                password_encrypted = excluded.password_encrypted,
                api_region = excluded.api_region,
                patient_id = excluded.patient_id,
                patient_name = excluded.patient_name,
                connected = excluded.connected,
                last_sync_status = excluded.last_sync_status,
                last_error = excluded.last_error,
                auto_sync_minutes = excluded.auto_sync_minutes,
                updated_at = excluded.updated_at
            """,
            (
                data["email"],
                data["password_encrypted"],
                data.get("api_region", "LA"),
                data.get("patient_id"),
                data.get("patient_name"),
                1 if data.get("connected", True) else 0,
                data.get("last_sync_at"),
                data.get("last_sync_status"),
                data.get("last_error"),
                data.get("auto_sync_minutes", 5),
                now,
            ),
        )
    return get_librelinkup_account() or {}


def update_librelinkup_sync(success: bool, inserted: int, error: str | None) -> None:
    now = _utcnow()
    with get_connection() as conn:
        conn.execute(
            """
            UPDATE librelinkup_account SET
                last_sync_at = ?,
                last_sync_status = ?,
                last_error = ?,
                updated_at = ?
            WHERE id = 1
            """,
            (
                now,
                "ok" if success else "error",
                error,
                now,
            ),
        )


def clear_librelinkup_account() -> None:
    with get_connection() as conn:
        conn.execute("DELETE FROM librelinkup_account WHERE id = 1")
