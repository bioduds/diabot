# DiabAI

<p align="center">
  <img src="assets/images/DiabAI.png" alt="DiabAI logo" width="260" />
</p>

DiabAI is an Android-first Flutter prototype for structured diabetes event logging. Its finite-state-machine (FSM) kernel controls conversation flow; an optional on-device Gemma 4 E4B model (`.litertlm`, run via `flutter_gemma`) is limited to semantic event extraction.

The authoritative repository documentation is in the [root README](../README.md). It covers architecture, safety limits, storage boundaries, model setup, and the relationship between DiabAI and the independent GlycoGuide web app.

## Look and feel

The app applies a single dark, violet-accented theme app-wide (`lib/app_theme.dart`), including login, onboarding, chat, and the profile view. The assistant's chat avatar uses the same mark as the logo:

<p align="center">
  <img src="assets/images/diabai_icon_small.png" alt="DiabAI chat avatar" width="56" />
</p>

The Android launcher icon is generated from the same source artwork (`assets/images/master.png`) at every standard density, from `mipmap-mdpi` through `mipmap-xxxhdpi`.

## Run

```bash
flutter pub get
flutter test test/orchestrator_test.dart
flutter test test/fsm_mermaid_contract_test.dart
flutter run
```

DiabAI does not use Ollama. To enable free-text semantic extraction, manually copy a compatible Gemma 4 E4B `.litertlm` model to Android device storage (default: `/sdcard/Download/gemma-4-E4B-it.litertlm`) and grant **All files access**. After login, DiabAI loads the model automatically before starting the chat or first-login onboarding, with a retry screen when either prerequisite is unavailable.

The model runs through `flutter_gemma`/`flutter_gemma_litertlm` (see [lib/llm_runtime.dart](lib/llm_runtime.dart)); RAG embeddings still run on a separate on-device `llama_cpp_dart` runtime and are unaffected by this. `flutter_gemma` has no grammar/JSON-schema constrained decoding, so structured extraction relies on few-shot prompting plus a defensive parser that discards malformed output rather than a hard grammar.

Without the external model, quick replies and bare numeric glucose entries remain available through the deterministic FSM.

Free-text input enters the generic `SemanticInterpreter`, implemented on-device by the Gemma extractor. It returns structured event candidates and fields rather than conversational output; the deterministic Kernel accepts only interpretations at or above its confidence threshold. The model prompt includes natural-language meal examples such as `Agora a fome apertou`. Every normal collection prompt offers `Outras opções`, which opens the generic event menu while retaining any pending event on the deterministic stack.

When the interpreter returns `unknown` (no matching event), its `free_reply` text is shaped by the **Nuno** persona — see [docs/fsm/nuno.mmd](docs/fsm/nuno.mmd) and [lib/nlu.dart](lib/nlu.dart). DiabAI is the product; Nuno is the conversational persona shown in the chat header and this one free-text reply path. The persona is calm, objective, never alarmist or childish, explains when asked, and stays fast and decisive if the recent context suggests an emergency. It only shapes wording: it never changes `DiabAIGlobalState` or the event lifecycle, calculates a dose, or diagnoses. A short rolling window of recent chat turns (`FsmContract.nunoContextWindowTurns`, currently 3) is passed to the prompt so replies stay coherent with the conversation, never in Guided Mode.

## FSM specification

The persisted FSM maps are [docs/fsm/kernel.mmd](docs/fsm/kernel.mmd), [docs/fsm/lifecycle.mmd](docs/fsm/lifecycle.mmd), [docs/fsm/emergency.mmd](docs/fsm/emergency.mmd), [docs/fsm/time_engine.mmd](docs/fsm/time_engine.mmd), [docs/fsm/meal.mmd](docs/fsm/meal.mmd), [docs/fsm/profile_engine.mmd](docs/fsm/profile_engine.mmd), [docs/fsm/profile_view.mmd](docs/fsm/profile_view.mmd), [docs/fsm/profile_lifecycle.mmd](docs/fsm/profile_lifecycle.mmd), [docs/fsm/global_context.mmd](docs/fsm/global_context.mmd), [docs/fsm/initialization.mmd](docs/fsm/initialization.mmd), and [docs/fsm/nuno.mmd](docs/fsm/nuno.mmd). Mermaid ignores their `%% fsm-contract` JSON headers; the verifier reads those headers and checks them against the canonical Dart contract in [lib/events.dart](lib/events.dart).

Run the drift check with:

```bash
flutter test test/fsm_mermaid_contract_test.dart
```

It verifies declared states, event types, ordering, auditable lifecycle edges, and emergency signals/threshold. It does not prove arbitrary Mermaid layout or every control-flow branch; changes to the FSM contract must update the code and the relevant `.mmd` file together.

The Time Engine in [lib/time_engine.dart](lib/time_engine.dart) produces timestamp-based context from the current event stack and the last 24 hours of local event history. Its initial emergency rule composes low-normal glucose, recent insulin, and recent intense exercise. Reported event times remain free-text context until a future Mermaid-defined module normalizes them; no new global state or event lifecycle is introduced.

The [lib/profile_engine.dart](lib/profile_engine.dart) Profile Engine maintains a passive local SQLite snapshot of facts explicitly offered in normal conversation and available Firebase-authenticated identity data (name, email, and photo URL). Each fact has a confidence value, timestamp, and contribution to a completeness score; it enriches the global context for the Emergency, Priority, Knowledge, and Profile View consumers. It never asks profile questions, adds a state, makes a recommendation, or applies medical reasoning. Missing facts remain data for the Knowledge Engine to decide whether to surface.

The [lib/profile_view.dart](lib/profile_view.dart) Profile View is a dynamic, known-only projection of `ProfileContext`. It renders identity and the priority-weighted completeness indicator, organizes general facts under `Dados Gerais`, and places health facts in ascending priority sections. The profile avatar comes from the authenticated account when available; otherwise, the user can select a local photo from the camera or gallery. This is the only input on the page: it does not collect health facts, render placeholders for unknown facts, ask profile questions, or apply medical reasoning.

![Validated Profile View on a Galaxy A56](docs/images/profile-view-a56.png)

The screenshot was captured during device validation and anonymized before inclusion: identity and health values are redacted while the rendered hierarchy remains visible.

The Meal module is declared in [docs/fsm/meal.mmd](docs/fsm/meal.mmd). It uses the existing generic missing-field lifecycle to distinguish a meal already eaten from a planned meal, record food details and stated carbohydrate quantities, and offer generic context. It does not create a global state, change emergency or priority behavior, calculate insulin, or recommend a dose.

## Glucose chart and CGM sync

[lib/cgm_sync_engine.dart](lib/cgm_sync_engine.dart) is declared in [docs/fsm/cgm.mmd](docs/fsm/cgm.mmd). Once a LibreLinkUp account is connected, it polls the unofficial LibreLinkUp "graph" endpoint every `FsmContract.cgmSyncIntervalSeconds` while the app is in the foreground and stores fetched readings as ordinary `EventType.glucose` events with `EventSource.cgm`. When the store gateway supports it (`CgmWindowGateway`, implemented by [lib/local_db.dart](lib/local_db.dart)), each sync deletes and fully replaces the locally stored CGM readings covering the fetched window before reinserting it, so a corrected re-parse of a period can never leave a stale, differently-timestamped duplicate of the same real reading sitting alongside it. It never touches the live conversation stack and never runs the Priority/Emergency engines directly.

[lib/glucose_chart.dart](lib/glucose_chart.dart) is a read-only AGP-style view over that same local event log (manual entries and CGM auto-sync alike), reached from the profile view. It plots a selectable rolling window (8h–7d) with in-range shading, per-bucket averages, and a template-based (non-LLM) summary of the visible window. Pull-to-refresh and a once-a-minute timer both reload local data and re-fetch a live [lib/librelinkup.dart](lib/librelinkup.dart) snapshot (current reading, trend arrow, sensor, and patient-configured target range), merging the live reading into the plotted series so the current-reading number is always exactly the graph's last point. Press-and-hold on the chart draws a vertical dashed line from the touched point to the top of the chart with the glucose value labeled there, colored by whether it falls inside the target range. A settings screen reached through the app-bar gear icon holds the period and source (`manual`/`cgm`/`all`) filters, keeping the main chart on one screen without scrolling.

The first-login [lib/initialization.dart](lib/initialization.dart) module is entered through the active `onboarding` global state after the external model is ready. It saves the local profile on completion and does not run again while that profile exists.

### Evolving the FSM

The kernel grows through modular event behavior, not event-specific conversation states. Start each behavior change with complete Mermaid diagrams and their contract, then assess event lifecycle, emergency, priority, and knowledge impact; create tests before implementing Dart.

Classify the feature first: new `EventType`, new `FieldSpec`, `EmergencyEngine` rule, `PriorityEngine` rule, or `KnowledgeEngine`-only change. Do not add states such as `mealState` or `glucoseState`; change global states, `lifecycle.mmd`, or `emergency.mmd` only when the feature actually changes those concerns. The enforceable agent workflow is defined in [../AGENTS.md](../AGENTS.md).

### Handoff package

To give another programmer the complete FSM specification and its executable references, create the handoff archive with:

```bash
docs/create_fsm_handoff_zip.sh
```

It writes [docs/zip/diabai-fsm-handoff.zip](docs/zip/diabai-fsm-handoff.zip), containing this README, all Mermaid maps, the Dart FSM contract, orchestrator, Profile Engine, Profile View, Time Engine, and their focused test suites. The script verifies that every required file exists before replacing the archive.
