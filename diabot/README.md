# Diabot

Diabot is an Android-first Flutter prototype for structured diabetes event logging. Its finite-state-machine (FSM) kernel controls conversation flow; an optional on-device Gemma GGUF is limited to semantic event extraction.

The authoritative repository documentation is in the [root README](../README.md). It covers architecture, safety limits, storage boundaries, model setup, and the relationship between Diabot and the independent GlycoGuide web app.

## Run

```bash
flutter pub get
flutter test test/orchestrator_test.dart
flutter run
```

Diabot does not use Ollama. To enable free-text semantic extraction, manually copy a compatible GGUF to Android device storage (default: `/sdcard/Download/gemma-3-4b-Q4_0.gguf`), grant **All files access**, then initialize it from the cloud icon in the app.

Without the external model, quick replies and bare numeric glucose entries remain available through the deterministic FSM.
