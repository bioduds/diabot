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

## FSM specification

The persisted FSM maps are [docs/fsm/kernel.mmd](docs/fsm/kernel.mmd), [docs/fsm/lifecycle.mmd](docs/fsm/lifecycle.mmd), [docs/fsm/emergency.mmd](docs/fsm/emergency.mmd), [docs/fsm/time_engine.mmd](docs/fsm/time_engine.mmd), [docs/fsm/meal.mmd](docs/fsm/meal.mmd), [docs/fsm/profile_engine.mmd](docs/fsm/profile_engine.mmd), [docs/fsm/profile_view.mmd](docs/fsm/profile_view.mmd), [docs/fsm/profile_lifecycle.mmd](docs/fsm/profile_lifecycle.mmd), [docs/fsm/global_context.mmd](docs/fsm/global_context.mmd), and [docs/fsm/initialization.mmd](docs/fsm/initialization.mmd). Mermaid ignores their `%% fsm-contract` JSON headers; the verifier reads those headers and checks them against the canonical Dart contract in [lib/events.dart](lib/events.dart).

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
