from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class UserProfile(BaseModel):
    name: str | None = None
    glucose_unit: Literal["mg/dL", "mmol/L"] = "mg/dL"
    basal_insulin: str | None = None
    basal_units: float | None = None
    basal_schedule: str | None = None
    bolus_insulin: str | None = None
    insulin_to_carb_ratio: float | None = Field(None, description="grams of carbs per 1 unit of insulin")
    correction_factor: float | None = Field(None, description="mg/dL drop per 1 unit of insulin")
    target_glucose_low: float | None = None
    target_glucose_high: float | None = None
    weight_unit: Literal["kg", "lb"] = "kg"
    libre_device: str = "FreeStyle Libre 2 Plus"
    disclaimer_accepted: bool = False


class CarbLogCreate(BaseModel):
    timestamp: str | None = None
    carbs_grams: float
    meal_description: str | None = None
    bolus_units: float | None = None
    notes: str | None = None


class ExerciseLogCreate(BaseModel):
    timestamp: str | None = None
    activity_type: str
    duration_minutes: int | None = None
    intensity: Literal["light", "moderate", "vigorous"] | None = None
    notes: str | None = None


class WeightLogCreate(BaseModel):
    timestamp: str | None = None
    weight: float
    unit: Literal["kg", "lb"] = "kg"
    notes: str | None = None


class InsulinLogCreate(BaseModel):
    timestamp: str | None = None
    insulin_type: str
    units: float
    reason: Literal["meal", "correction", "basal", "other"] | None = None
    notes: str | None = None


class ChatRequest(BaseModel):
    message: str


class LibreLinkUpConnect(BaseModel):
    email: str
    password: str
    region: Literal["US", "EU", "EU2", "LA", "AU", "CA", "DE", "FR", "JP", "AE", "AP", "RU"] = "LA"


class CheckinItem(BaseModel):
    category: str
    priority: Literal["high", "medium", "low"]
    message: str
    overdue_hours: float | None = None
