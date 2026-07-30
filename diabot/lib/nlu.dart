import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import 'events.dart';

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

  const NluExtraction({
    this.events = const [],
    this.entities = const {},
    this.confidence = 0,
  });

  factory NluExtraction.empty() => const NluExtraction();

  @override
  String toString() => 'NluExtraction(events: $events, entities: $entities, '
      'confidence: $confidence)';
}

/// Wraps the on-device Gemma model (via [LlamaParent]) to do ONLY
/// multi-event extraction from a single user utterance. It never streams
/// a conversational answer and never decides what DIABOT does next.
class IntentClassifier {
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

  /// GBNF grammar mirroring the JSON schema in [_systemPrompt] exactly.
  /// Required because the base (pretrained, non-instruction-tuned) 4B
  /// checkpoint has no notion of "stop after answering" and will happily
  /// keep rambling past the JSON if left unconstrained — grammar-
  /// constrained decoding forces every generated token to stay inside this
  /// exact shape and ends the moment it's complete.
  static const grammar = r'''
root ::= "{\"events\": [" events-list "], \"entities\": {\"glucose\": " num-or-null ", \"food\": " str-or-null ", \"carbs_grams\": " num-or-null ", \"duration\": " num-or-null ", \"intensity\": " str-or-null ", \"insulin_type\": " str-or-null ", \"dose\": " num-or-null ", \"symptom_type\": " str-or-null "}, \"confidence\": " conf-value "}"
events-list ::= "\"" event-value "\"" (", \"" event-value "\"")*
event-value ::= "glucose" | "meal" | "insulin" | "exercise" | "illness" | "ketones" | "medication" | "symptoms" | "cgm" | "profile" | "question" | "unknown"
conf-value ::= "0" ("." [0-9] [0-9]?)? | "1" ("." "0")?
str-or-null ::= "null" | "\"" [^"\n]* "\""
num-or-null ::= "null" | "-"? [0-9]+ ("." [0-9]+)?
''';

  static const _systemPrompt = '''
Você é um extrator de eventos. Você NUNCA conversa, NUNCA explica e NUNCA responde ao usuário. Sua única função é ler uma frase em português (pode ser transcrição de voz, com pequenos erros, e pode conter mais de um evento) e devolver APENAS um objeto JSON, em uma única linha, sem nenhum texto antes ou depois, sem markdown, sem crases.

Os eventos possíveis são exatamente estes (pode haver mais de um na mesma frase):
- "glucose": o usuário informou um valor numérico de glicemia (mg/dL).
- "meal": o usuário comeu ou vai comer algo.
- "insulin": o usuário aplicou ou vai aplicar insulina.
- "exercise": o usuário fez, faz ou vai fazer atividade física.
- "illness": o usuário relata doença, infecção, febre ou mal-estar.
- "ketones": o usuário relata ou mediu cetonas.
- "medication": o usuário relata outro medicamento além de insulina.
- "symptoms": sintomas de hipoglicemia ou hiperglicemia (tremor, suor frio, tontura, fraqueza, fome súbita, confusão, muita sede, muita vontade de urinar, visão turva, cansaço extremo).
- "cgm": menção a sensor de glicemia contínua (CGM).
- "profile": informação pessoal/cadastral (ex: tipo de diabetes, peso).
- "question": o usuário está fazendo uma pergunta e quer uma explicação.
- "unknown": qualquer outra coisa, incluindo cumprimentos, ou frases que não se encaixam acima.

Formato de saída (sempre as mesmas chaves; use null quando não souber; "events" é uma lista com 1 ou mais itens):
{"events": [<um ou mais dos valores acima>], "entities": {"glucose": <número ou null>, "food": <string ou null>, "carbs_grams": <número ou null>, "duration": <número ou null>, "intensity": <string ou null>, "insulin_type": <string ou null>, "dose": <número ou null>, "symptom_type": <"hypo", "hyper" ou null>}, "confidence": <0.0 a 1.0>}

Exemplos:
Entrada: comi uma pizza e tomei 8 unidades de fiasp
Saída: {"events": ["meal", "insulin"], "entities": {"glucose": null, "food": "pizza", "carbs_grams": null, "duration": null, "intensity": null, "insulin_type": "Fiasp", "dose": 8}, "confidence": 0.9}

Entrada: 117
Saída: {"events": ["glucose"], "entities": {"glucose": 117, "food": null, "carbs_grams": null, "duration": null, "intensity": null, "insulin_type": null, "dose": null, "symptom_type": null}, "confidence": 0.95}

Entrada: minha glicemia está em 117, vou comer uma pizza e vou caminhar 40 minutos
Saída: {"events": ["glucose", "meal", "exercise"], "entities": {"glucose": 117, "food": "pizza", "carbs_grams": null, "duration": 40, "intensity": null, "insulin_type": null, "dose": null, "symptom_type": null}, "confidence": 0.9}

Entrada: estou tremendo e suando frio
Saída: {"events": ["symptoms"], "entities": {"glucose": null, "food": null, "carbs_grams": null, "duration": null, "intensity": null, "insulin_type": null, "dose": null, "symptom_type": "hypo"}, "confidence": 0.9}

Entrada: sai para correr
Saída: {"events": ["exercise"], "entities": {"glucose": null, "food": null, "carbs_grams": null, "duration": null, "intensity": null, "insulin_type": null, "dose": null, "symptom_type": null}, "confidence": 0.9}

Entrada: tomei 6 unidades de glargina
Saída: {"events": ["insulin"], "entities": {"glucose": null, "food": null, "carbs_grams": null, "duration": null, "intensity": null, "insulin_type": "glargina", "dose": 6, "symptom_type": null}, "confidence": 0.9}

Entrada: estou com fome
Saída: {"events": ["meal"], "entities": {"glucose": null, "food": null, "carbs_grams": null, "duration": null, "intensity": null, "insulin_type": null, "dose": null, "symptom_type": null}, "confidence": 0.8}

Entrada: por que a insulina baixa a glicemia?
Saída: {"events": ["question"], "entities": {"glucose": null, "food": null, "carbs_grams": null, "duration": null, "intensity": null, "insulin_type": null, "dose": null, "symptom_type": null}, "confidence": 0.85}

Entrada: oi, bom dia
Saída: {"events": ["unknown"], "entities": {"glucose": null, "food": null, "carbs_grams": null, "duration": null, "intensity": null, "insulin_type": null, "dose": null, "symptom_type": null}, "confidence": 0.9}
''';

  final LlamaParent llamaParent;

  IntentClassifier(this.llamaParent);

  /// Classifies [userText]. Returns [NluExtraction.empty] on any failure
  /// (model not ready, timeout, malformed JSON) so the orchestrator always
  /// has a safe fallback instead of crashing or showing raw model output.
  Future<NluExtraction> classify(String userText) async {
    if (llamaParent.status != LlamaStatus.ready) return NluExtraction.empty();

    // Raw few-shot completion instead of a chat template: the base
    // (pretrained-only) checkpoint was never trained on Gemma's
    // <start_of_turn> role markup, so wrapping the prompt in it just adds
    // out-of-distribution noise. Plain "Entrada:/Saída:" continuation
    // matches the exact pattern already shown in [_systemPrompt].
    final sanitized = userText.replaceAll('\n', ' ').trim();
    final promptText = '$_systemPrompt\nEntrada: $sanitized\nSaída: ';

    final buffer = StringBuffer();
    final completer = Completer<void>();

    final tokenSub = llamaParent.stream.listen((token) {
      buffer.write(token);
    });
    final compSub = llamaParent.completions.listen((event) {
      if (!completer.isCompleted) completer.complete();
    });

    try {
      await llamaParent.sendPrompt(promptText);
      await completer.future.timeout(const Duration(seconds: 30),
          onTimeout: () {});
    } catch (_) {
      // Fall through; buffer may be partially filled or empty, handled by
      // _parse below.
    } finally {
      await tokenSub.cancel();
      await compSub.cancel();
    }

    if (kDebugMode) {
      // ignore: avoid_print
      print('[IntentClassifier] raw output for "$sanitized": '
          '${buffer.toString()}');
    }

    return _parse(buffer.toString());
  }

  NluExtraction _parse(String raw) {
    // Balanced-brace extraction: the "confidence" key sits after the
    // nested "entities" object closes, so the outer object's last two
    // `}` are never adjacent — a lazy `\{.*?\}\s*\}` regex can never
    // match this shape. Taking the first `{` through the last `}` is
    // robust regardless of internal nesting.
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) return NluExtraction.empty();
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
      if (events.isEmpty) return NluExtraction.empty();

      final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.0;

      final rawEntities =
          (json['entities'] as Map<String, dynamic>?) ?? const {};
      final entities = <String, dynamic>{};
      for (final entry in rawEntities.entries) {
        if (entry.value != null) entities[entry.key] = entry.value;
      }

      return NluExtraction(
          events: events, entities: entities, confidence: confidence);
    } catch (_) {
      return NluExtraction.empty();
    }
  }
}
