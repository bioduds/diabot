# Diabot / GlycoGuide — Local LLM CGM Assistant for Type 1 Diabetes

This repository contains two related, local-first projects for Type 1 diabetes support powered by local LLMs (no cloud, no data leaving your machine):

- **[`app/`](app/)** — **GlycoGuide**, a FastAPI web app (documented below) that tracks CGM data, carbs, exercise, weight, and insulin, and chats with you about patterns via [Ollama](https://ollama.com).
- **[`diabot/`](diabot/README.md)** — **Diabot**, a Flutter mobile MVP for simple chat conversations with a local model (Gemma 3 / TinyLlama) over Ollama.

---

## GlycoGuide (web app)

GlycoGuide is a **local-first** web app that uses [Ollama](https://ollama.com) to help you organize and interpret:

- **CGM data** from FreeStyle Libre 2 Plus (via LibreLink / LibreView CSV export)
- **Carbohydrate counting** and meal boluses
- **Exercise** logs
- **Weight** measurements
- **Insulin** types, units, I:C ratio, and correction factor

The assistant proactively reminds you to log missing data and discusses glucose **patterns** in plain language — but it is **not a doctor** and never adjusts insulin doses.

## Important disclaimer

GlycoGuide provides educational decision support only. It does **not** diagnose, prescribe, or replace your endocrinology team. For hypoglycemia, severe hyperglycemia, or any emergency, follow your care plan and seek appropriate medical help immediately.

## Requirements

- Python 3.10+
- [Ollama](https://ollama.com) running locally
- A pulled model (default: `llama3.2`)

```bash
ollama serve          # if not already running
ollama pull llama3.2  # or set OLLAMA_MODEL=gemma3:4b
```

## Quick start

```bash
cd diabetes-cgm-assistant
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --host 127.0.0.1 --port 8080
```

Open [http://127.0.0.1:8080](http://127.0.0.1:8080)

1. Complete your **insulin profile** and accept the disclaimer
2. **Connect LibreLinkUp** with your email and password (recommended), or import a LibreView CSV
3. Log **carbs, exercise, weight, and insulin**
4. Chat with GlycoGuide about trends and what to track next

## LibreLinkUp connection (recommended)

GlycoGuide can pull CGM readings directly from **LibreLinkUp** using your login and password.

### Setup steps

1. Install [LibreLinkUp](https://www.librelinkup.com/) on your phone and create an account
2. In the **LibreLink** app (on the patient's phone), go to **Share** or **Connected Apps** and invite your LibreLinkUp account
3. Accept the invitation in LibreLinkUp
4. In GlycoGuide, enter your **LibreLinkUp email and password**
5. Select your **region** (Latin America / LA for Brazil) and click **Connect & sync**

GlycoGuide syncs automatically every 5 minutes while running. You can also click **Sync now** anytime.

Credentials are stored **locally** on your machine, encrypted with a key in `data/.fernet_key`. They never leave your computer except to authenticate with Abbott's LibreLinkUp API.

## Importing LibreLink / LibreView CSV (alternative)

Abbott does not expose a public LibreLink API for personal use. The supported workflow today:

1. Sync FreeStyle Libre 2 Plus with the **LibreLink** app
2. Open [LibreView](https://www.libreview.com) → Glucose History → **Download glucose data** (CSV)
3. In GlycoGuide, click **Import LibreLink CSV**

The parser accepts common Abbott export column names (`Device Timestamp`, `Historic Glucose mg/dL`, etc.).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_BASE_URL` | `http://localhost:11434` | Ollama API URL |
| `OLLAMA_MODEL` | `llama3.2` | Model name |

Example:

```bash
export OLLAMA_MODEL=gemma3:4b
uvicorn app.main:app --reload --port 8080
```

## Data storage

All data stays on your machine in:

```
diabetes-cgm-assistant/data/cgm_assistant.db
```

## Architecture

```
app/
  main.py       # FastAPI routes + static UI
  database.py   # SQLite persistence
  llm.py        # Ollama chat with medical guardrails
  librelink.py      # LibreView CSV parser
  librelinkup_sync.py  # LibreLinkUp login + sync
  secrets.py        # Local credential encryption
  checkins.py   # Proactive reminder engine
  static/       # Web UI
```

## Proactive check-ins

GlycoGuide nudges you when data is stale:

| Category | Default interval |
| ---------- | ------------------ |
| Carbs | 5 hours |
| Exercise | 8 hours |
| Weight | 7 days |
| Insulin | 12 hours |
| CGM review | 6 hours |

## Roadmap ideas

- LibreLink (patient app) direct login in addition to LibreLinkUp
- Time-in-range and AGP-style summaries
- Nightscout / Tidepool import
- Scheduled background check-in messages

## License

MIT — use at your own risk; not a medical device.
