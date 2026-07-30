# Diabot

Diabot is an Android-first Flutter prototype for structured diabetes event logging. Its finite-state-machine (FSM) kernel controls conversation flow; an optional on-device Gemma GGUF is limited to semantic event extraction.

The authoritative repository documentation is in the [root README](../README.md). It covers architecture, safety limits, storage boundaries, model setup, and the relationship between Diabot and the independent GlycoGuide web app.

## Run

```bash
flutter pub get
flutter test test/orchestrator_test.dart
flutter test test/fsm_mermaid_contract_test.dart
flutter run
```

Diabot does not use Ollama. To enable free-text semantic extraction, manually copy a compatible GGUF to Android device storage (default: `/sdcard/Download/gemma-3-4b-Q4_0.gguf`) and grant **All files access**. After login, Diabot loads the GGUF automatically before starting the chat or first-login onboarding, with a retry screen when either prerequisite is unavailable.

Without the external model, quick replies and bare numeric glucose entries remain available through the deterministic FSM.

## FSM specification

The persisted FSM maps are [docs/fsm/kernel.mmd](docs/fsm/kernel.mmd), [docs/fsm/lifecycle.mmd](docs/fsm/lifecycle.mmd), [docs/fsm/emergency.mmd](docs/fsm/emergency.mmd), [docs/fsm/time_engine.mmd](docs/fsm/time_engine.mmd), and [docs/fsm/initialization.mmd](docs/fsm/initialization.mmd). Mermaid ignores their `%% fsm-contract` JSON headers; the verifier reads those headers and checks them against the canonical Dart contract in [lib/events.dart](lib/events.dart).

Run the drift check with:

```bash
flutter test test/fsm_mermaid_contract_test.dart
```

It verifies declared states, event types, ordering, auditable lifecycle edges, and emergency signals/threshold. It does not prove arbitrary Mermaid layout or every control-flow branch; changes to the FSM contract must update the code and the relevant `.mmd` file together.

The Time Engine in [lib/time_engine.dart](lib/time_engine.dart) produces timestamp-based context from the current event stack and the last 24 hours of local event history. Its initial emergency rule composes low-normal glucose, recent insulin, and recent intense exercise. Reported event times remain free-text context until a future Mermaid-defined module normalizes them; no new global state or event lifecycle is introduced.

The first-login [lib/initialization.dart](lib/initialization.dart) module is entered through the active `onboarding` global state after the external model is ready. It saves the local profile on completion and does not run again while that profile exists.

### Evolving the FSM

The kernel grows through modular event behavior, not event-specific conversation states. Start each behavior change with complete Mermaid diagrams and their contract, then assess event lifecycle, emergency, priority, and knowledge impact; create tests before implementing Dart.

Classify the feature first: new `EventType`, new `FieldSpec`, `EmergencyEngine` rule, `PriorityEngine` rule, or `KnowledgeEngine`-only change. Do not add states such as `mealState` or `glucoseState`; change global states, `lifecycle.mmd`, or `emergency.mmd` only when the feature actually changes those concerns. The enforceable agent workflow is defined in [../AGENTS.md](../AGENTS.md).

### Handoff package

To give another programmer the complete FSM specification and its executable references, create the handoff archive with:

```bash
docs/create_fsm_handoff_zip.sh
```

It writes [docs/zip/diabot-fsm-handoff.zip](docs/zip/diabot-fsm-handoff.zip), containing this README, all Mermaid maps, the Dart FSM contract and orchestrator, and both FSM test suites. The script verifies that every required file exists before replacing the archive.
