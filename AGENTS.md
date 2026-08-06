# Agent Guide

## Repository Boundaries

- This repository has two independent applications: GlycoGuide (`app/`, FastAPI/Python) and DiabAI (`diabai/`, Flutter). They do not share an API, runtime, database, or model pipeline. Do not wire one into the other without an explicit request.
- Read the [root README](README.md) before changing behavior that affects data handling, model use, or medical-safety messaging.
- Neither application is medical decision support. Do not add insulin-dose calculations, treatment prescriptions, diagnostic claims, or emergency-dispatch behavior.

## GlycoGuide

- Keep health data local by default. `OLLAMA_BASE_URL` may be non-local, so do not silently broaden data egress or log credentials/health data.
- Run locally with the commands in [README.md](README.md). Its SQLite runtime data is under `data/` and must not be committed.

## DiabAI

- The deterministic FSM is the authority; the on-device LLM only extracts structured events. Keep state transitions in [diabai/lib/orchestrator.dart](diabai/lib/orchestrator.dart) generic over global state and missing fields. Put event schemas, priority, validation, and emergency rules in [diabai/lib/events.dart](diabai/lib/events.dart).
- When changing the FSM contract, update the affected Mermaid specification in [diabai/docs/fsm](diabai/docs/fsm), the contract test, and behavior tests together. Run:

  ```bash
  cd diabai
  flutter test test/orchestrator_test.dart test/fsm_mermaid_contract_test.dart
  ```

- Build number changes (`version`'s `+N` in `diabai/pubspec.yaml`) intentionally clear DiabAI local preferences, auth state, and SQLite data at launch. Bump it before creating a new device-test APK; do not bump it for source-only checks.
- The external GGUF is manually loaded from Android storage. Keep loading manual and avoid concurrent native model loading because RAG, STT, and the large GGUF can exceed device memory.
- Do not commit model weights or generated Flutter build outputs. When changing the RAG knowledge base, regenerate embeddings with [diabai/tools/precompute_embeddings.py](diabai/tools/precompute_embeddings.py) using its documented llama.cpp-compatible toolchain.

## DiabAI FSM Evolution

The DiabAI kernel is mature enough to grow by modules without another large architectural redesign. Preserve the separation between the global FSM (`DiabAIGlobalState`), event lifecycle (`EventStatus`), `EmergencyEngine`, `PriorityEngine`, and `KnowledgeEngine`.

- Start every FSM behavior change with complete Mermaid (`.mmd`) diagrams. Do not implement a rule in Dart before its Mermaid specification and contract are defined.
- Never create an event-specific global state such as `mealState` or `glucoseState`. Model the behavior with `EventType`, `FieldSpec`, generic `DiabAIGlobalState`, and `EventStatus`.
- A new behavior must be classified before implementation as a new `EventType`, new `FieldSpec`, `EmergencyEngine` rule, `PriorityEngine` rule, or `KnowledgeEngine`-only change. Change global states, `lifecycle.mmd`, or `emergency.mmd` only when that classification requires it.
- For new event behavior, change in this order: Mermaid -> FSM contract -> event lifecycle -> Emergency Engine impact -> Priority Engine impact -> Knowledge Engine impact -> tests -> Dart implementation.
- Do not make unrelated architectural suggestions or change unrelated components when extending the FSM.

### Prompt: FSM Extension Only

```text
Você é responsável apenas por ampliar a FSM do DiabAI.

REGRAS:

1. SEMPRE comece pela FSM em Mermaid.
2. NÃO implemente Dart primeiro.
3. NÃO crie estados específicos para refeições, glicemia, insulina etc.
4. Utilize apenas:
  - DiabAIGlobalState
  - EventType
  - FieldSpec
  - EventStatus
  - Emergency Engine
  - Priority Engine
  - Knowledge Engine

O fluxo obrigatório é:

Mermaid
↓
Contrato da FSM
↓
Lifecycle do evento
↓
Impacto no Emergency Engine
↓
Impacto no Priority Engine
↓
Impacto no Knowledge Engine
↓
Testes
↓
Implementação em Dart

Sua resposta deverá conter SOMENTE:

1. FSM em Mermaid
2. O contrato da FSM que será alterado
3. Os EventTypes necessários
4. Os FieldSpecs necessários
5. As transições do lifecycle
6. Os testes que precisam ser criados
7. Os arquivos Dart que precisam ser alterados

Não faça sugestões arquiteturais extras.
Não altere componentes não relacionados.
```

### Prompt: Add a Feature

```text
Analise toda a FSM atual antes de implementar.

A nova funcionalidade deverá responder obrigatoriamente:

1. Trata-se de:
- novo EventType?
- novo FieldSpec?
- nova regra do Emergency Engine?
- nova regra do Priority Engine?
- apenas uma alteração do Knowledge Engine?

2. A FSM global precisará mudar?
Se não, NÃO crie novos estados.

3. O lifecycle do evento mudou?
Se não, NÃO altere lifecycle.mmd.

4. O Emergency Engine mudou?
Se não, NÃO altere emergency.mmd.

5. Produza primeiro os diagramas Mermaid completos.
```

## Handoff and Validation

- Regenerate the programmer handoff ZIP after changing its inputs: `cd diabai && docs/create_fsm_handoff_zip.sh`.
- For changes that touch Flutter source, run focused tests first, then `flutter analyze` on touched files. Preserve the existing local-storage and audit-gateway boundaries.
