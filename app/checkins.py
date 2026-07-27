from __future__ import annotations

from datetime import datetime, timezone

from app import database as db
from app.models import CheckinItem

# Hours between proactive prompts by category
CHECKIN_INTERVALS = {
    "carbs": 5,
    "exercise": 8,
    "weight": 168,  # weekly
    "insulin": 12,
    "glucose_review": 6,
}


def _hours_since(iso_timestamp: str | None) -> float | None:
    if not iso_timestamp:
        return None
    try:
        then = datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
        if then.tzinfo is None:
            then = then.replace(tzinfo=timezone.utc)
        delta = datetime.now(timezone.utc) - then
        return delta.total_seconds() / 3600
    except ValueError:
        return None


def get_pending_checkins() -> list[CheckinItem]:
    profile = db.get_profile()
    state = db.get_checkin_state()
    items: list[CheckinItem] = []

    if not profile or not profile.get("disclaimer_accepted"):
        items.append(
            CheckinItem(
                category="setup",
                priority="high",
                message=(
                    "Before we begin: please complete your insulin profile and accept the "
                    "medical disclaimer. I am a decision-support tool, not a doctor."
                ),
            )
        )
        return items

    last_carb = db.latest_timestamp("carb_logs")
    hours = _hours_since(last_carb)
    if hours is None or hours >= CHECKIN_INTERVALS["carbs"]:
        items.append(
            CheckinItem(
                category="carbs",
                priority="high" if hours is None or hours >= 8 else "medium",
                message=(
                    "Have you eaten recently? Please log carbohydrates (grams) and any meal "
                    "bolus so I can relate them to your CGM trend."
                ),
                overdue_hours=round(hours, 1) if hours is not None else None,
            )
        )

    last_exercise = db.latest_timestamp("exercise_logs")
    hours = _hours_since(last_exercise)
    if hours is None or hours >= CHECKIN_INTERVALS["exercise"]:
        items.append(
            CheckinItem(
                category="exercise",
                priority="medium",
                message=(
                    "Any physical activity today? Exercise affects insulin sensitivity — "
                    "log type, duration, and intensity when you can."
                ),
                overdue_hours=round(hours, 1) if hours is not None else None,
            )
        )

    last_weight = db.latest_timestamp("weight_logs")
    hours = _hours_since(last_weight)
    if hours is None or hours >= CHECKIN_INTERVALS["weight"]:
        items.append(
            CheckinItem(
                category="weight",
                priority="high" if hours is None or hours >= 336 else "medium",
                message=(
                    "Regular weight checks help spot longer-term patterns. "
                    "When did you last weigh yourself?"
                ),
                overdue_hours=round(hours, 1) if hours is not None else None,
            )
        )

    last_insulin = db.latest_timestamp("insulin_logs")
    hours = _hours_since(last_insulin)
    if hours is None or hours >= CHECKIN_INTERVALS["insulin"]:
        basal = profile.get("basal_insulin") or "basal insulin"
        bolus = profile.get("bolus_insulin") or "bolus insulin"
        items.append(
            CheckinItem(
                category="insulin",
                priority="medium",
                message=(
                    f"Please confirm recent insulin doses ({basal} / {bolus}) and units so "
                    "I can interpret glucose changes accurately."
                ),
                overdue_hours=round(hours, 1) if hours is not None else None,
            )
        )

    glucose = db.glucose_stats(hours=24)
    if glucose["count"] == 0:
        items.append(
            CheckinItem(
                category="glucose",
                priority="high",
                message=(
                    "No recent CGM readings found. Connect LibreLinkUp or import a "
                    "LibreView CSV export so I can review your glucose patterns."
                ),
            )
        )
    else:
        review_hours = _hours_since(state.get("last_glucose_review"))
        if review_hours is None or review_hours >= CHECKIN_INTERVALS["glucose_review"]:
            items.append(
                CheckinItem(
                    category="glucose_review",
                    priority="medium",
                    message=(
                        f"Latest CGM: {glucose['latest']} {glucose['unit']} "
                        f"(24h avg {glucose['average']}). Ask me to review patterns "
                        "once you've logged recent meals and activity."
                    ),
                )
            )

    missing_profile_fields = []
    for field, label in [
        ("basal_insulin", "basal insulin type"),
        ("bolus_insulin", "bolus insulin type"),
        ("insulin_to_carb_ratio", "insulin-to-carb ratio"),
        ("correction_factor", "correction factor"),
    ]:
        if not profile.get(field):
            missing_profile_fields.append(label)

    if missing_profile_fields:
        items.append(
            CheckinItem(
                category="profile",
                priority="high",
                message=(
                    "Your insulin settings are incomplete: "
                    + ", ".join(missing_profile_fields)
                    + ". Update your profile so calculations and advice stay personalized."
                ),
            )
        )

    return items


def mark_checkin_sent(category: str) -> None:
    mapping = {
        "carbs": "last_carb_prompt",
        "exercise": "last_exercise_prompt",
        "weight": "last_weight_prompt",
        "insulin": "last_insulin_prompt",
        "glucose_review": "last_glucose_review",
    }
    field = mapping.get(category)
    if field:
        db.update_checkin_prompt(field)
