from __future__ import annotations

import csv
import io
import re
from datetime import datetime, timezone
from typing import Any


MMOL_TO_MGDL = 18.0182


def _parse_timestamp(raw: str) -> str | None:
    raw = raw.strip()
    if not raw:
        return None
    formats = [
        "%m/%d/%Y %H:%M",
        "%d/%m/%Y %H:%M",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%m-%d-%Y %H:%M",
    ]
    for fmt in formats:
        try:
            dt = datetime.strptime(raw, fmt)
            return dt.replace(tzinfo=timezone.utc).isoformat()
        except ValueError:
            continue
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.isoformat()
    except ValueError:
        return None


def _to_mgdl(value: float, unit_hint: str | None) -> float:
    if unit_hint and "mmol" in unit_hint.lower():
        return round(value * MMOL_TO_MGDL, 1)
    if value <= 30:
        return round(value * MMOL_TO_MGDL, 1)
    return round(value, 1)


def parse_librelink_csv(content: str, preferred_unit: str = "mg/dL") -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """
    Parse LibreView / LibreLink CSV exports.

    Supports common Abbott export layouts including:
    - Device Timestamp, Historic Glucose mmol/L
    - Device Timestamp, Record Type, Historic Glucose mg/dL
    """
    reader = csv.DictReader(io.StringIO(content))
    if not reader.fieldnames:
        raise ValueError("CSV file appears to be empty or missing headers.")

    fieldnames = [name.strip() for name in reader.fieldnames]
    normalized = {name.lower(): name for name in fieldnames}

    timestamp_col = _find_column(
        normalized,
        ["device timestamp", "timestamp", "date/time", "scan time", "datetime"],
    )
    glucose_col = _find_column(
        normalized,
        [
            "historic glucose mg/dl",
            "historic glucose mmol/l",
            "glucose mg/dl",
            "glucose mmol/l",
            "glucose value (mg/dl)",
            "glucose value (mmol/l)",
            "sensor glucose (mg/dl)",
            "sensor glucose (mmol/l)",
        ],
    )
    record_type_col = _find_column(normalized, ["record type", "type"])

    if not timestamp_col or not glucose_col:
        raise ValueError(
            "Could not find glucose timestamp/value columns. "
            "Export from LibreView as CSV with historic glucose readings."
        )

    unit_hint = glucose_col.lower()
    readings: list[dict[str, Any]] = []
    skipped = 0

    for row in reader:
        record_type = row.get(record_type_col, "").strip().lower() if record_type_col else ""
        if record_type and "glucose" not in record_type and record_type not in {"0", "1", "2"}:
            skipped += 1
            continue

        raw_value = row.get(glucose_col, "").strip()
        if not raw_value:
            skipped += 1
            continue

        try:
            value = float(re.sub(r"[^\d.]", "", raw_value))
        except ValueError:
            skipped += 1
            continue

        timestamp = _parse_timestamp(row.get(timestamp_col, ""))
        if not timestamp:
            skipped += 1
            continue

        mgdl = _to_mgdl(value, unit_hint)
        if preferred_unit == "mmol/L":
            stored_value = round(mgdl / MMOL_TO_MGDL, 1)
            unit = "mmol/L"
        else:
            stored_value = mgdl
            unit = "mg/dL"

        readings.append(
            {
                "timestamp": timestamp,
                "value": stored_value,
                "unit": unit,
                "source": "librelink",
            }
        )

    meta = {
        "parsed_rows": len(readings),
        "skipped_rows": skipped,
        "columns_detected": fieldnames,
    }
    return readings, meta


def _find_column(normalized: dict[str, str], candidates: list[str]) -> str | None:
    for candidate in candidates:
        if candidate in normalized:
            return normalized[candidate]
    for key, original in normalized.items():
        for candidate in candidates:
            if candidate.replace(" ", "") in key.replace(" ", ""):
                return original
    return None
