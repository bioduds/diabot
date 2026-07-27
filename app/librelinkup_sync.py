from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from pylibrelinkup import PyLibreLinkUp
from pylibrelinkup.api_url import APIUrl
from pylibrelinkup.exceptions import (
    AuthenticationError,
    EmailVerificationError,
    PrivacyPolicyError,
    PyLibreLinkUpError,
    RedirectError,
    TermsOfUseError,
)

from app import database as db
from app.secrets import decrypt, encrypt

MMOL_FACTOR = 18.0182

REGION_MAP = {
    "US": APIUrl.US,
    "EU": APIUrl.EU,
    "EU2": APIUrl.EU2,
    "LA": APIUrl.LA,
    "AU": APIUrl.AU,
    "CA": APIUrl.CA,
    "DE": APIUrl.DE,
    "FR": APIUrl.FR,
    "JP": APIUrl.JP,
    "AE": APIUrl.AE,
    "AP": APIUrl.AP,
    "RU": APIUrl.RU,
}

TREND_LABELS = {
    1: "falling quickly",
    2: "falling",
    3: "stable",
    4: "rising",
    5: "rising quickly",
}


def _region_from_code(code: str) -> APIUrl:
    return REGION_MAP.get(code.upper(), APIUrl.LA)


def _region_code(api_url: APIUrl) -> str:
    for code, value in REGION_MAP.items():
        if value == api_url:
            return code
    return "LA"


def _measurement_to_reading(measurement: Any, preferred_unit: str) -> dict[str, Any]:
    mgdl = float(measurement.value_in_mg_per_dl or 0)
    if mgdl <= 0:
        mgdl = float(measurement.value or 0) * MMOL_FACTOR

    if preferred_unit == "mmol/L":
        value = round(mgdl / MMOL_FACTOR, 1)
        unit = "mmol/L"
    else:
        value = round(mgdl, 1)
        unit = "mg/dL"

    ts = measurement.factory_timestamp or measurement.timestamp
    if isinstance(ts, datetime):
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        timestamp = ts.astimezone(timezone.utc).isoformat()
    else:
        timestamp = str(ts)

    trend_arrow = getattr(measurement, "trend_arrow", None)
    trend = TREND_LABELS.get(trend_arrow) if trend_arrow else None

    return {
        "timestamp": timestamp,
        "value": value,
        "unit": unit,
        "source": "librelinkup",
        "trend": trend,
    }


def _build_client(email: str, password: str, region_code: str) -> tuple[PyLibreLinkUp, str]:
    region = _region_from_code(region_code)
    client = PyLibreLinkUp(email=email, password=password, api_url=region)
    try:
        client.authenticate()
    except RedirectError as exc:
        region = exc.region
        client = PyLibreLinkUp(email=email, password=password, api_url=region)
        client.authenticate()
    return client, _region_code(region)


def connect_account(email: str, password: str, region_code: str = "LA") -> dict[str, Any]:
    email = email.strip()
    if not email or not password:
        raise ValueError("Email and password are required.")

    try:
        client, actual_region = _build_client(email, password, region_code)
    except AuthenticationError as exc:
        raise ValueError("Invalid LibreLinkUp email or password.") from exc
    except EmailVerificationError as exc:
        raise ValueError("Verify your LibreLinkUp email address in the app, then try again.") from exc
    except TermsOfUseError as exc:
        raise ValueError("Accept LibreLinkUp terms of use in the mobile app, then try again.") from exc
    except PrivacyPolicyError as exc:
        raise ValueError("Accept LibreLinkUp privacy policy in the mobile app, then try again.") from exc
    except PyLibreLinkUpError as exc:
        raise ValueError(f"LibreLinkUp error: {exc}") from exc

    patients = client.get_patients()
    if not patients:
        raise ValueError(
            "No patients linked to this LibreLinkUp account. "
            "In LibreLink, share data with this LibreLinkUp login first."
        )

    patient = patients[0]
    patient_id = str(getattr(patient, "patient_id", None) or getattr(patient, "id", ""))
    patient_name = " ".join(
        part for part in [getattr(patient, "first_name", ""), getattr(patient, "last_name", "")] if part
    ).strip()

    db.save_librelinkup_account(
        {
            "email": email,
            "password_encrypted": encrypt(password),
            "api_region": actual_region,
            "patient_id": patient_id,
            "patient_name": patient_name or None,
            "connected": 1,
            "last_sync_status": "connected",
            "last_error": None,
        }
    )

    sync_result = sync_glucose_data()
    return {
        "connected": True,
        "email": email,
        "patient_name": patient_name,
        "patient_id": patient_id,
        "region": actual_region,
        "sync": sync_result,
    }


def disconnect_account() -> None:
    db.clear_librelinkup_account()


def get_account_status() -> dict[str, Any]:
    account = db.get_librelinkup_account()
    if not account or not account.get("connected"):
        return {"connected": False}
    return {
        "connected": True,
        "email": account.get("email"),
        "patient_name": account.get("patient_name"),
        "patient_id": account.get("patient_id"),
        "region": account.get("api_region"),
        "last_sync_at": account.get("last_sync_at"),
        "last_sync_status": account.get("last_sync_status"),
        "last_error": account.get("last_error"),
        "auto_sync_minutes": account.get("auto_sync_minutes", 5),
    }


def sync_glucose_data() -> dict[str, Any]:
    account = db.get_librelinkup_credentials()
    if not account or not account.get("connected"):
        raise ValueError("LibreLinkUp is not connected.")

    email = account["email"]
    password = decrypt(account["password_encrypted"])
    region = account.get("api_region", "LA")
    patient_id = account.get("patient_id")
    profile = db.get_profile() or {}
    preferred_unit = profile.get("glucose_unit", "mg/dL")

    try:
        client, _ = _build_client(email, password, region)
        patients = client.get_patients()
        if not patients:
            raise ValueError("No linked patients found on LibreLinkUp.")

        patient = patients[0]
        if not patient_id:
            patient_id = str(getattr(patient, "patient_id", None) or getattr(patient, "id", ""))

        readings_map: dict[str, dict[str, Any]] = {}
        for fetch in (client.graph, client.logbook):
            try:
                measurements = fetch(patient_identifier=patient_id or patient)
            except TypeError:
                measurements = fetch(patient_identifier=patient)
            for measurement in measurements:
                reading = _measurement_to_reading(measurement, preferred_unit)
                readings_map[reading["timestamp"]] = reading

        readings = list(readings_map.values())
        inserted = db.insert_glucose_readings(readings)
        db.update_librelinkup_sync(success=True, inserted=inserted, error=None)
        return {
            "ok": True,
            "inserted": inserted,
            "fetched": len(readings),
            "patient_name": account.get("patient_name"),
        }
    except Exception as exc:
        db.update_librelinkup_sync(success=False, inserted=0, error=str(exc))
        raise ValueError(str(exc)) from exc
