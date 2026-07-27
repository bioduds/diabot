from __future__ import annotations

import json
import os
from typing import Any

import httpx

from app import database as db
from app.checkins import get_pending_checkins

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "gemma3:4b")

SYSTEM_PROMPT = """You are GlycoGuide, a local AI assistant for a person living with Type 1 Diabetes Mellitus.

IMPORTANT — LEGAL AND ETHICAL BOUNDARIES:
- You are NOT a doctor, endocrinologist, nurse, or licensed healthcare provider.
- You do NOT diagnose, prescribe, or tell the user what insulin dose to take.
- You provide educational pattern analysis and reminders to help the user discuss trends with their care team.
- Always encourage contacting their diabetes care team for dosing changes, emergencies, or concerning symptoms.
- For hypoglycemia (typically below 70 mg/dL / 3.9 mmol/L) or severe hyperglycemia, urge immediate action per their care plan and emergency services if needed.

DATA SOURCES:
- CGM: FreeStyle Libre 2 Plus via LibreLinkUp (live sync) or LibreView CSV import
- User-logged: carbohydrates, exercise, weight, insulin doses

YOUR ROLE:
1. Ask proactively for missing data (meals/carbs, exercise, weight, insulin) — incomplete logs limit your ability to help.
2. Relate glucose trends to logged carbs, insulin, and activity when possible.
3. Use the user's insulin types, units, I:C ratio, and correction factor from their profile — never assume different insulins.
4. Note patterns (post-meal rises, overnight stability, exercise-related lows) in plain language.
5. Be warm, concise, and structured. Use bullet points for clarity.
6. When uncertain, say what additional information would help.

Never claim medical authority. Frame insights as observations to verify with their healthcare team."""


def _build_context() -> str:
    profile = db.get_profile() or {}
    glucose = db.glucose_stats(hours=24)
    carbs = db.recent_rows("carb_logs", limit=8)
    exercise = db.recent_rows("exercise_logs", limit=5)
    weight = db.recent_rows("weight_logs", limit=3)
    insulin = db.recent_rows("insulin_logs", limit=8)
    checkins = get_pending_checkins()

    context = {
        "user_profile": {
            "name": profile.get("name"),
            "glucose_unit": profile.get("glucose_unit", "mg/dL"),
            "basal_insulin": profile.get("basal_insulin"),
            "basal_units": profile.get("basal_units"),
            "bolus_insulin": profile.get("bolus_insulin"),
            "insulin_to_carb_ratio": profile.get("insulin_to_carb_ratio"),
            "correction_factor": profile.get("correction_factor"),
            "target_range": [
                profile.get("target_glucose_low"),
                profile.get("target_glucose_high"),
            ],
            "cgm_device": profile.get("libre_device", "FreeStyle Libre 2 Plus"),
        },
        "glucose_last_24h": glucose,
        "recent_carbs": carbs,
        "recent_exercise": exercise,
        "recent_weight": weight,
        "recent_insulin": insulin,
        "pending_reminders": [item.model_dump() for item in checkins],
    }
    return json.dumps(context, indent=2)


async def chat_with_llm(user_message: str) -> str:
    history = db.get_chat_history(limit=20)
    context = _build_context()

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "system",
            "content": f"Current user data snapshot (JSON):\n{context}",
        },
    ]
    messages.extend(history)
    messages.append({"role": "user", "content": user_message})

    db.add_chat_message("user", user_message)

    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            response = await client.post(
                f"{OLLAMA_BASE_URL}/api/chat",
                json={
                    "model": OLLAMA_MODEL,
                    "messages": messages,
                    "stream": False,
                    "options": {"temperature": 0.4, "num_ctx": 8192},
                },
            )
            response.raise_for_status()
            payload = response.json()
            assistant_message = payload["message"]["content"].strip()
    except httpx.ConnectError:
        assistant_message = (
            "I cannot reach Ollama on localhost:11434. Start it with `ollama serve`, "
            f"ensure `{OLLAMA_MODEL}` is pulled, then try again."
        )
    except httpx.HTTPStatusError as exc:
        assistant_message = (
            f"Ollama returned an error ({exc.response.status_code}). "
            f"Verify the model `{OLLAMA_MODEL}` is available: `ollama pull {OLLAMA_MODEL}`"
        )
    except Exception as exc:
        assistant_message = f"Unexpected error contacting the local LLM: {exc}"

    db.add_chat_message("assistant", assistant_message)
    return assistant_message


async def generate_welcome_message() -> str:
    checkins = get_pending_checkins()
    profile = db.get_profile()
    name = (profile or {}).get("name") or "there"

    reminder_text = "\n".join(f"- {item.message}" for item in checkins[:4])
    if not reminder_text:
        reminder_text = "- You're caught up on logging. Ask me to review your recent CGM patterns."

    prompt = (
        f"Greet {name} briefly as GlycoGuide. Mention you run locally and are not a doctor. "
        f"Include these pending reminders naturally:\n{reminder_text}\n"
        "Keep it under 120 words."
    )
    return await chat_with_llm(prompt)


async def ollama_status() -> dict[str, Any]:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(f"{OLLAMA_BASE_URL}/api/tags")
            response.raise_for_status()
            models = [m["name"] for m in response.json().get("models", [])]
            return {
                "connected": True,
                "model": OLLAMA_MODEL,
                "model_available": any(OLLAMA_MODEL.split(":")[0] in m for m in models),
                "models": models,
            }
    except Exception as exc:
        return {"connected": False, "model": OLLAMA_MODEL, "error": str(exc)}
