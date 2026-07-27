from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app import database as db
from app.checkins import get_pending_checkins, mark_checkin_sent
from app.librelink import parse_librelink_csv
from app.librelinkup_sync import (
    connect_account,
    disconnect_account,
    get_account_status,
    sync_glucose_data,
)
from app.llm import chat_with_llm, generate_welcome_message, ollama_status
from app.models import (
    CarbLogCreate,
    ChatRequest,
    ExerciseLogCreate,
    InsulinLogCreate,
    LibreLinkUpConnect,
    UserProfile,
    WeightLogCreate,
)

STATIC_DIR = Path(__file__).resolve().parent / "static"

_sync_task: asyncio.Task | None = None


async def _auto_sync_loop() -> None:
    while True:
        account = db.get_librelinkup_credentials()
        if account:
            minutes = account.get("auto_sync_minutes") or 5
            try:
                await asyncio.to_thread(sync_glucose_data)
            except Exception:
                pass
            await asyncio.sleep(max(minutes, 1) * 60)
        else:
            await asyncio.sleep(60)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _sync_task
    db.init_db()
    _sync_task = asyncio.create_task(_auto_sync_loop())
    yield
    if _sync_task:
        _sync_task.cancel()
        try:
            await _sync_task
        except asyncio.CancelledError:
            pass


app = FastAPI(
    title="GlycoGuide",
    description="Local LLM assistant for Type 1 Diabetes CGM pattern analysis",
    version="0.2.0",
    lifespan=lifespan,
)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@app.get("/api/health")
async def health():
    status = await ollama_status()
    return {"status": "ok", "ollama": status}


@app.get("/api/profile")
def get_profile():
    profile = db.get_profile()
    return profile or {}


@app.put("/api/profile")
def update_profile(profile: UserProfile):
    if not profile.disclaimer_accepted:
        raise HTTPException(
            status_code=400,
            detail="You must accept the medical disclaimer before using GlycoGuide.",
        )
    return db.save_profile(profile.model_dump())


@app.get("/api/glucose/stats")
def glucose_stats(hours: int = 24):
    return db.glucose_stats(hours=hours)


@app.get("/api/glucose/recent")
def glucose_recent(limit: int = 100):
    return db.recent_rows("glucose_readings", limit=limit)


@app.post("/api/glucose/import")
async def import_glucose(file: UploadFile = File(...)):
    profile = db.get_profile() or {}
    preferred_unit = profile.get("glucose_unit", "mg/dL")
    content = (await file.read()).decode("utf-8-sig", errors="replace")
    try:
        readings, meta = parse_librelink_csv(content, preferred_unit=preferred_unit)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    inserted = db.insert_glucose_readings(readings)
    return {"inserted": inserted, "parsed": meta["parsed_rows"], "meta": meta}


@app.get("/api/librelinkup/status")
def librelinkup_status():
    return get_account_status()


@app.post("/api/librelinkup/connect")
def librelinkup_connect(credentials: LibreLinkUpConnect):
    try:
        return connect_account(
            email=credentials.email,
            password=credentials.password,
            region_code=credentials.region,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/librelinkup/sync")
def librelinkup_sync():
    try:
        return sync_glucose_data()
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.delete("/api/librelinkup/disconnect")
def librelinkup_disconnect():
    disconnect_account()
    return {"ok": True}


@app.post("/api/logs/carbs")
def log_carbs(entry: CarbLogCreate):
    payload = entry.model_dump()
    payload["timestamp"] = payload.get("timestamp") or _now_iso()
    return db.add_carb_log(payload)


@app.post("/api/logs/exercise")
def log_exercise(entry: ExerciseLogCreate):
    payload = entry.model_dump()
    payload["timestamp"] = payload.get("timestamp") or _now_iso()
    return db.add_exercise_log(payload)


@app.post("/api/logs/weight")
def log_weight(entry: WeightLogCreate):
    payload = entry.model_dump()
    payload["timestamp"] = payload.get("timestamp") or _now_iso()
    return db.add_weight_log(payload)


@app.post("/api/logs/insulin")
def log_insulin(entry: InsulinLogCreate):
    payload = entry.model_dump()
    payload["timestamp"] = payload.get("timestamp") or _now_iso()
    return db.add_insulin_log(payload)


@app.get("/api/logs/{log_type}")
def get_logs(log_type: str, limit: int = 20):
    mapping = {
        "carbs": "carb_logs",
        "exercise": "exercise_logs",
        "weight": "weight_logs",
        "insulin": "insulin_logs",
    }
    table = mapping.get(log_type)
    if not table:
        raise HTTPException(status_code=404, detail="Unknown log type")
    return db.recent_rows(table, limit=limit)


@app.get("/api/checkins")
def checkins():
    return [item.model_dump() for item in get_pending_checkins()]


@app.post("/api/checkins/{category}/ack")
def ack_checkin(category: str):
    mark_checkin_sent(category)
    return {"ok": True}


@app.get("/api/chat/history")
def chat_history():
    return db.get_chat_history(limit=50)


@app.post("/api/chat")
async def chat(request: ChatRequest):
    if not request.message.strip():
        raise HTTPException(status_code=400, detail="Message cannot be empty")
    profile = db.get_profile()
    if not profile or not profile.get("disclaimer_accepted"):
        raise HTTPException(
            status_code=403,
            detail="Complete your profile and accept the disclaimer first.",
        )
    reply = await chat_with_llm(request.message.strip())
    return {"reply": reply}


@app.post("/api/chat/welcome")
async def chat_welcome():
    profile = db.get_profile()
    if not profile or not profile.get("disclaimer_accepted"):
        raise HTTPException(status_code=403, detail="Complete setup first.")
    reply = await generate_welcome_message()
    return {"reply": reply}


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")
