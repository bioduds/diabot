import 'dart:async';
import 'dart:convert';

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

  Future<NluExtraction> interpret(String userText);
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

  static const _systemPrompt = '''
Extraia eventos de uma frase em português. Responda APENAS um JSON, sem conversa ou markdown.

Eventos: glucose (glicemia), meal (comeu, vai comer, fome ou alimentos), insulin, exercise, illness, ketones, medication, symptoms (tremor, suor frio, tontura, fraqueza, confusão, sede intensa), cgm, profile, question, unknown.

Use os nomes exatos dos eventos. Em entities, emita somente dados encontrados: glucose, food, carbs_grams, duration, intensity, insulin_type, dose, symptom_type e campos profile_*. Se events for ["unknown"], inclua também free_reply com uma resposta curta, acolhedora e sem orientação médica. Não calcule, recomende nem invente dados.

Entrada: agora a fome apertou
Saída: {"events": ["meal"], "entities": {}, "confidence": 0.9}

Entrada: comi pizza e tomei 8 unidades de fiasp
Saída: {"events": ["meal", "insulin"], "entities": {"food": "pizza", "insulin_type": "fiasp", "dose": 8}, "confidence": 0.9}

Entrada: estou tremendo e suando frio
Saída: {"events": ["symptoms"], "entities": {"symptom_type": "hypo"}, "confidence": 0.9}

Entrada: quero conversar sobre meu dia
Saída: {"events": ["unknown"], "entities": {"free_reply": "Claro. Me conte o que aconteceu hoje."}, "confidence": 0.8}
''';

  final LocalLLMRuntime llmRuntime;
  final SemanticDiagnostics? diagnostics;
  bool _isInterpreting = false;

  IntentClassifier(this.llmRuntime, {this.diagnostics});

  /// Interprets [userText]. Returns [NluExtraction.empty] on any failure
  /// (model not ready, timeout, malformed JSON) so the orchestrator always
  /// has a safe fallback instead of crashing or showing raw model output.
  @override
  Future<NluExtraction> interpret(String userText) async {
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
    final promptText = '$_systemPrompt\nEntrada: $sanitized\nSaída: ';

    _isInterpreting = true;
    var completed = false;
    var timedOut = false;
    String? failureType;
    var response = '';
    try {
      response = await llmRuntime.generate(promptText).timeout(
        const Duration(seconds: 30),
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
