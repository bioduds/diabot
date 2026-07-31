import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'events.dart';
import 'llm_runtime.dart';
import 'semantic_diagnostics.dart';

/// Structured result of parsing one piece of free-form user input (typed
/// or transcribed) into zero or more events plus shared entities.
///
/// Architecture note: the on-device LLM's ONLY job is to turn natural
/// language into this structured shape. It never decides a state
/// transition, never asks a question, never stores anything and never
/// answers the user directly — the FSM in `orchestrator.dart` alone owns
/// all of that. This keeps a 4B model doing something it's actually
/// reliable at (short natural-language extraction in Portuguese) instead
/// of acting as an "artificial endocrinologist" or a state machine.
class NluExtraction {
  final List<EventType> events;
  final Map<String, dynamic> entities;
  final double confidence;
  final String? freeTextResponse;

  const NluExtraction({
    this.events = const [],
    this.entities = const {},
    this.confidence = 0,
    this.freeTextResponse,
  });

  factory NluExtraction.empty() => const NluExtraction();

  @override
  String toString() => 'NluExtraction(events: $events, entities: $entities, '
      'confidence: $confidence)';
}

/// Wraps the on-device Gemma model (via [LocalLLMRuntime]) to do ONLY
/// multi-event extraction from a single user utterance. It never streams
/// a conversational answer and never decides what DIABOT does next.
/// Converts free-form user language into structured event candidates.
///
/// The Kernel consumes only [NluExtraction], so this interface is the
/// replaceable semantic boundary between an on-device LLM and the FSM.
abstract interface class SemanticInterpreter {
  static const minimumConfidence =
      FsmContract.semanticInterpreterMinimumConfidence;

  /// Interprets [userText] (typed text or a quick-reply label). When
  /// [audioBytes] is provided (a recorded voice message), it is sent to
  /// the model directly instead of [userText] — Gemma 4 is multimodal and
  /// extracts events from speech itself, so no separate transcription
  /// step is needed.
  Future<NluExtraction> interpret(String userText, {Uint8List? audioBytes});
}

/// On-device Gemma implementation of [SemanticInterpreter].
class IntentClassifier implements SemanticInterpreter {
  static const _eventNames = {
    'glucose',
    'meal',
    'insulin',
    'exercise',
    'illness',
    'ketones',
    'medication',
    'symptoms',
    'cgm',
    'profile',
    'question',
    'unknown',
  };

  // Content below is a hand-maintained digest of the true FSM contract
  // (eventDefinitions in events.dart + docs/fsm/*.mmd), not a raw dump of
  // the Mermaid files: loading ~17KB of diagram syntax at runtime would
  // multiply prefill time on-device for no extraction benefit. Keep this
  // in sync when eventDefinitions or docs/fsm/modules.mmd change.
  static const _systemPrompt = '''
Extraia eventos de uma frase em português. Responda APENAS um JSON válido, sem markdown ou texto extra: {"events": [...], "entities": {...}, "confidence": 0-1}.

Eventos (nomes exatos): glucose (nível/medição de glicemia), meal (comeu, vai comer, fome, alimentos), insulin (aplicou ou vai aplicar insulina, unidades), exercise (atividade física, intensidade/duração), illness (doença, febre, mal-estar geral — não sintomas de glicemia), ketones (medição de cetonas), medication (remédio que não é insulina), symptoms (tremor, suor frio, tontura, fraqueza, confusão, sede ou fome súbita — possível hipo/hiperglicemia), cgm (sensor de monitoramento contínuo), profile (dado pessoal estável: idade, peso, altura, tipo de diabetes, bomba de insulina etc, mencionado de passagem), question (pergunta educativa sobre diabetes, sem relatar um evento), unknown (nada acima se aplica claramente — conversa livre).

Entidades (emita só o que encontrar): glucose, food, carbs_grams, duration, intensity, insulin_type, dose, symptom_type, free_reply, profile_diabetes_type, profile_weight_kg, profile_height_cm, profile_age_years, profile_sex, profile_cgm, profile_insulin_pump, profile_insulin_carb_ratio, profile_correction_factor, profile_hypoglycemia_unawareness, profile_diagnosis_duration, profile_knowledge_level.

Regras: pode haver mais de um evento na mesma frase; use confidence abaixo de 0.5 quando a frase for ambígua; se events for ["unknown"], inclua free_reply (resposta curta, acolhedora, sem orientação médica); nunca calcule dose, recomende tratamento ou invente dados.

Entrada: agora a fome apertou
Saída: {"events": ["meal"], "entities": {}, "confidence": 0.9}

Entrada: comi pizza e tomei 8 unidades de fiasp
Saída: {"events": ["meal", "insulin"], "entities": {"food": "pizza", "insulin_type": "fiasp", "dose": 8}, "confidence": 0.9}

Entrada: estou tremendo e suando frio
Saída: {"events": ["symptoms"], "entities": {"symptom_type": "hypo"}, "confidence": 0.9}

Entrada: minha glicose deu 180
Saída: {"events": ["glucose"], "entities": {"glucose": 180}, "confidence": 0.95}

Entrada: fui correr 30 minutos, intensidade moderada
Saída: {"events": ["exercise"], "entities": {"duration": "30 minutos", "intensity": "moderada"}, "confidence": 0.9}

Entrada: tenho 45 anos e peso 70kg
Saída: {"events": ["profile"], "entities": {"profile_age_years": 45, "profile_weight_kg": 70}, "confidence": 0.85}

Entrada: quero conversar sobre meu dia
Saída: {"events": ["unknown"], "entities": {"free_reply": "Claro. Me conte o que aconteceu hoje."}, "confidence": 0.8}
''';

  final LocalLLMRuntime llmRuntime;
  final SemanticDiagnostics? diagnostics;
  bool _isInterpreting = false;

  IntentClassifier(this.llmRuntime, {this.diagnostics});

  /// Interprets [userText], or a recorded voice message when [audioBytes]
  /// is set. Returns [NluExtraction.empty] on any failure (model not
  /// ready, timeout, malformed JSON) so the orchestrator always has a
  /// safe fallback instead of crashing or showing raw model output.
  @override
  Future<NluExtraction> interpret(String userText, {Uint8List? audioBytes}) async {
    if (llmRuntime.status != LLMStatus.ready || _isInterpreting) {
      _logRuntimeOutcome(
        'skipped',
        runtimeStatus: llmRuntime.status,
        alreadyInterpreting: _isInterpreting,
      );
      diagnostics?.record(SemanticDebugSnapshot(
        stage: 'skipped',
        runtimeStatus: llmRuntime.status,
        timestamp: DateTime.now(),
        failure: _isInterpreting
            ? 'Há outra interpretação em andamento.'
            : 'O modelo local não está pronto para gerar.',
      ));
      return NluExtraction.empty();
    }

    // The local runtime applies Gemma's turn template before generation. Keeping
    // the examples in the user turn gives the instruction-tuned model a
    // compact, consistent extraction task.
    final sanitized = userText.replaceAll('\n', ' ').trim();
    final promptText = audioBytes == null
        ? '$_systemPrompt\nEntrada: $sanitized\nSaída: '
        : '$_systemPrompt\nEntrada: (ouça a fala no áudio a seguir e '
            'extraia dela exatamente como nos exemplos acima)\nSaída: ';

    _isInterpreting = true;
    var completed = false;
    var timedOut = false;
    String? failureType;
    var response = '';
    try {
      final generation = audioBytes == null
          ? llmRuntime.generate(promptText)
          : llmRuntime.generateWithAudio(promptText, audioBytes);
      // 4B-parameter prefill alone measured 24-28s on-device (Galaxy A56),
      // so 30s was cutting off otherwise-successful generations; the
      // audio path also carries the encoder/adapter passes on top of that.
      response = await generation.timeout(
        const Duration(seconds: 75),
        onTimeout: () {
          timedOut = true;
          return '';
        },
      );
      completed = !timedOut;
    } catch (error) {
      failureType = error.runtimeType.toString();
      // Fall through; response may be empty, handled by _parse below.
    } finally {
      _isInterpreting = false;
    }

    _logRuntimeOutcome(
      'completed',
      runtimeStatus: llmRuntime.status,
      completed: completed,
      timedOut: timedOut,
      failureType: failureType,
      characterCount: response.length,
    );
    final extraction = _parse(response);
    diagnostics?.record(SemanticDebugSnapshot(
      stage: 'completed',
      runtimeStatus: llmRuntime.status,
      timestamp: DateTime.now(),
      outputCharacters: response.length,
      hasJson: response.contains('{') && response.contains('}'),
      eventNames: extraction.events.map((event) => event.name).toList(),
      confidence: extraction.confidence == 0 ? null : extraction.confidence,
      timedOut: timedOut,
      failure: failureType,
    ));
    return extraction;
  }

  NluExtraction _parse(String raw) {
    // Balanced-brace extraction: the "confidence" key sits after the
    // nested "entities" object closes, so the outer object's last two
    // `}` are never adjacent — a lazy `\{.*?\}\s*\}` regex can never
    // match this shape. Taking the first `{` through the last `}` is
    // robust regardless of internal nesting.
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      _logResponseShape(raw.length, hasJson: false);
      return NluExtraction.empty();
    }
    try {
      final json =
          jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;

      final rawEvents = (json['events'] as List?) ?? const [];
      final events = <EventType>[];
      for (final item in rawEvents) {
        final name = (item as String?)?.trim();
        if (name == null || !_eventNames.contains(name)) continue;
        final type = eventTypeFromString(name);
        if (type != null && !events.contains(type)) events.add(type);
      }
      if (events.isEmpty) {
        _logResponseShape(raw.length, hasJson: true, eventCount: 0);
        return NluExtraction.empty();
      }

      final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.0;

      final rawEntities =
          (json['entities'] as Map<String, dynamic>?) ?? const {};
        final freeTextResponse = (rawEntities['free_reply'] as String?)?.trim();
      final entities = <String, dynamic>{};
      for (final entry in rawEntities.entries) {
        if (entry.value != null) entities[entry.key] = entry.value;
      }

      _logResponseShape(raw.length,
          hasJson: true, eventCount: events.length, confidence: confidence);
      return NluExtraction(
        events: events,
        entities: entities,
        confidence: confidence,
        freeTextResponse:
          freeTextResponse == null || freeTextResponse.isEmpty
            ? null
            : freeTextResponse,
        );
    } catch (_) {
      _logResponseShape(raw.length, hasJson: true, parseFailed: true);
      return NluExtraction.empty();
    }
  }

  void _logResponseShape(
    int characterCount, {
    required bool hasJson,
    int? eventCount,
    double? confidence,
    bool parseFailed = false,
  }) {
    // ignore: avoid_print
    print(
      'DIABOT_NLU Semantic response: chars=$characterCount json=$hasJson '
      'events=${eventCount ?? '-'} confidence=${confidence ?? '-'} '
      'parseFailed=$parseFailed',
    );
  }

  void _logRuntimeOutcome(
    String stage, {
    required LLMStatus runtimeStatus,
    bool alreadyInterpreting = false,
    bool? completed,
    bool? timedOut,
    String? failureType,
    int? characterCount,
  }) {
    // ignore: avoid_print
    print(
      'DIABOT_NLU Semantic runtime: stage=$stage status=$runtimeStatus '
      'busy=$alreadyInterpreting completed=${completed ?? '-'} '
      'timedOut=${timedOut ?? '-'} failure=${failureType ?? '-'} '
      'chars=${characterCount ?? '-'}',
    );
  }
}
