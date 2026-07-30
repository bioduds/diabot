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

Diabot does not use Ollama. To enable free-text semantic extraction, manually copy a compatible GGUF to Android device storage (default: `/sdcard/Download/gemma-3-4b-Q4_0.gguf`), grant **All files access**, then initialize it from the cloud icon in the app.

Without the external model, quick replies and bare numeric glucose entries remain available through the deterministic FSM.

## FSM specification

The persisted FSM maps are [docs/fsm/kernel.mmd](docs/fsm/kernel.mmd), [docs/fsm/lifecycle.mmd](docs/fsm/lifecycle.mmd), and [docs/fsm/emergency.mmd](docs/fsm/emergency.mmd). Mermaid ignores their `%% fsm-contract` JSON headers; the verifier reads those headers and checks them against the canonical Dart contract in [lib/events.dart](lib/events.dart).

Run the drift check with:

```bash
flutter test test/fsm_mermaid_contract_test.dart
```

It verifies declared states, event types, ordering, auditable lifecycle edges, and emergency signals/threshold. It does not prove arbitrary Mermaid layout or every control-flow branch; changes to the FSM contract must update the code and the relevant `.mmd` file together.

### Evolving the FSM

The kernel grows through modular event behavior, not event-specific conversation states. Start each behavior change with complete Mermaid diagrams and their contract, then assess event lifecycle, emergency, priority, and knowledge impact; create tests before implementing Dart.

Classify the feature first: new `EventType`, new `FieldSpec`, `EmergencyEngine` rule, `PriorityEngine` rule, or `KnowledgeEngine`-only change. Do not add states such as `mealState` or `glucoseState`; change global states, `lifecycle.mmd`, or `emergency.mmd` only when the feature actually changes those concerns. The enforceable agent workflow is defined in [../AGENTS.md](../AGENTS.md).

### Handoff package

To give another programmer the complete FSM specification and its executable references, create the handoff archive with:

```bash
docs/create_fsm_handoff_zip.sh
```

It writes [docs/zip/diabot-fsm-handoff.zip](docs/zip/diabot-fsm-handoff.zip), containing this README, all Mermaid maps, the Dart FSM contract and orchestrator, and both FSM test suites. The script verifies that every required file exists before replacing the archive.
