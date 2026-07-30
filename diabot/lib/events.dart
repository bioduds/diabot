import 'dart:convert';

/// What actually happened, per the user's own architectural rule: "There
/// are no meal states, glucose states or insulin states. There are only
/// events and missing pieces of information." This is the full universe of
/// things DIABOT can recognize — never a conversational state.
enum EventType {
  symptoms,
  glucose,
  insulin,
  meal,
  exercise,
  illness,
  ketones,
  medication,
  cgm,
  profile,
  question,
  unknown,
}

EventType? eventTypeFromString(String value) {
  for (final type in EventType.values) {
    if (type.name == value) return type;
  }
  return null;
}

/// The FSM's global states. None of these are per-event — `waitingInformation`
/// applies identically whether the missing piece belongs to a meal, an
/// insulin dose, or anything else; the FSM never branches on event identity.
enum DiabotGlobalState {
  idle,
  parsing,
  prioritizing,
  waitingInformation,
  validating,
  storing,
  clarification,
  resuming,
  enrichingContext,
  emergency,
  learningUser,
  onboarding,
  education,
}

/// How a [FieldSpec]'s answer should be parsed. The FSM only ever branches
/// on this (generic) shape, never on which event the field belongs to.
enum FieldKind { yesNo, number, option, freeText }

/// Where an event entered the kernel. Sources are evidence, not states.
enum EventSource { userText, quickReply, numericInput, semanticParser, cgm, system }

/// Each event has one lifecycle position at a time.
enum EventStatus {
  queued,
  waitingInformation,
  validating,
  stored,
  discarded,
  escalated,
}

/// One piece of information an event may still be missing, and how to ask
/// for it. This — plus [eventDefinitions] below — is the ONLY place that
/// "knows" meals need carbs or hypoglycemia needs a fast-insulin check;
/// the FSM's control flow itself stays generic over [FieldKind].
class FieldSpec {
  const FieldSpec({
    required this.key,
    required this.question,
    required this.kind,
    this.quickReplies,
    this.optionValues,
    this.numericInputHint,
    this.dependsOn,
    this.required = true,
    this.priority = 0,
  });

  final String key;
  final String question;
  final FieldKind kind;

  /// Display labels for a yes/no or fixed-option question.
  final List<String>? quickReplies;

  /// For [FieldKind.option]: lowercase substring -> canonical stored value.
  final Map<String, String>? optionValues;

  final String? numericInputHint;

  /// This field only applies when `known[dependsOn.key] == dependsOn.value`
  /// (e.g. carbs grams only matters if carbs are known at all).
  final MapEntry<String, dynamic>? dependsOn;

  /// Optional fields enrich a record but never block its completion.
  final bool required;

  /// Lower asks first among an event's currently-missing fields.
  final int priority;
}

/// One occurrence of an [EventType] on the event stack, with whatever data
/// has been extracted or answered so far.
class EventInstance {
  EventInstance({
    required this.type,
    Map<String, dynamic>? data,
    DateTime? createdAt,
    this.source = EventSource.userText,
    String? id,
  })  : data = data ?? <String, dynamic>{},
        createdAt = createdAt ?? DateTime.now(),
        id = id ?? _newId();

  static int _sequence = 0;

  static String _newId() =>
      'event-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

  final String id;
  final EventType type;
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final EventSource source;
  EventStatus status = EventStatus.queued;
  String? statusReason;

  void transitionTo(EventStatus next, {String? reason}) {
    status = next;
    statusReason = reason;
  }
}

/// Immutable audit record emitted for every meaningful event lifecycle move.
class KernelTransition {
  const KernelTransition({
    required this.eventId,
    required this.eventType,
    required this.from,
    required this.to,
    required this.globalState,
    required this.at,
    this.reason,
  });

  final String eventId;
  final EventType eventType;
  final EventStatus from;
  final EventStatus to;
  final DiabotGlobalState globalState;
  final DateTime at;
  final String? reason;
}

/// Read-only history required by the Emergency Engine.
abstract interface class RecentEventReader {
  Future<List<Map<String, dynamic>>> recentEventsOfType(
    String type,
    Duration within,
  );
}

/// The only boundary through which the FSM persists data or its audit log.
abstract interface class FsmStoreGateway {
  Future<void> storeEvent(EventInstance event);
  Future<void> storeSystemEvent(String type, Map<String, dynamic> data);
  Future<void> recordTransition(KernelTransition transition);
}

/// The data table declaring, per event type, which fields are required and
/// how to ask for each. `cgm`, `profile`, `question` and `unknown` have no
/// required fields (stubs / handled outside the missing-field machinery).
final Map<EventType, List<FieldSpec>> eventDefinitions = {
  EventType.glucose: const [
    FieldSpec(
      key: 'value',
      question: 'Qual sua glicemia atual, se souber?',
      kind: FieldKind.number,
      numericInputHint: 'Glicemia atual (mg/dL)',
      priority: 0,
    ),
    FieldSpec(
      key: 'usedInsulin',
      question: 'Você utilizou alguma insulina nas últimas 4 horas?',
      kind: FieldKind.yesNo,
      quickReplies: ['Sim', 'Não'],
      priority: 1,
    ),
  ],
  EventType.insulin: const [
    FieldSpec(
      key: 'dose',
      question: 'Quantas unidades você aplicou?',
      kind: FieldKind.number,
      numericInputHint: 'Unidades de insulina',
      priority: 0,
    ),
  ],
  EventType.meal: const [
    FieldSpec(
      key: 'carbsKnown',
      question: 'Você sabe aproximadamente quantos gramas de carboidratos '
          'tinha essa refeição?',
      kind: FieldKind.yesNo,
      quickReplies: ['Sim, sei', 'Não sei'],
      priority: 0,
    ),
    FieldSpec(
      key: 'carbsGrams',
      question: 'Quantos gramas de carboidratos, aproximadamente?',
      kind: FieldKind.number,
      numericInputHint: 'Gramas de carboidrato',
      dependsOn: MapEntry('carbsKnown', true),
      priority: 1,
    ),
  ],
  EventType.exercise: const [
    FieldSpec(
      key: 'intensity',
      question: 'Que bom que você se exercitou! A atividade foi:',
      kind: FieldKind.option,
      quickReplies: ['Leve', 'Moderada', 'Intensa'],
      optionValues: {'leve': 'leve', 'moderad': 'moderada', 'intens': 'intensa'},
      priority: 0,
    ),
  ],
  EventType.illness: const [
    FieldSpec(
      key: 'illnessType',
      question: 'O que você está sentindo ou qual condição está enfrentando?',
      kind: FieldKind.freeText,
    ),
  ],
  EventType.ketones: const [
    FieldSpec(
      key: 'ketoneResult',
      question: 'Qual foi o resultado da medição de cetonas, se souber?',
      kind: FieldKind.freeText,
    ),
    FieldSpec(
      key: 'value',
      question: 'Qual sua glicemia atual, se souber?',
      kind: FieldKind.number,
      numericInputHint: 'Glicemia atual (mg/dL)',
      priority: 1,
    ),
  ],
  EventType.medication: const [
    FieldSpec(
      key: 'medicationName',
      question: 'Qual medicamento você tomou ou quer registrar?',
      kind: FieldKind.freeText,
    ),
  ],
  EventType.symptoms: const [
    FieldSpec(
      key: 'symptomType',
      question: 'Isso parece mais com sintomas de açúcar baixo ou açúcar alto?',
      kind: FieldKind.option,
      quickReplies: ['Baixo (hipoglicemia)', 'Alto (hiperglicemia)'],
      optionValues: {'baixo': 'hypo', 'hipo': 'hypo', 'alto': 'hyper', 'hiper': 'hyper'},
      priority: 0,
    ),
    FieldSpec(
      key: 'value',
      question: 'Qual sua glicemia atual, se souber?',
      kind: FieldKind.number,
      numericInputHint: 'Glicemia atual (mg/dL)',
      priority: 1,
    ),
    FieldSpec(
      key: 'usedFastInsulin',
      question: 'Você utilizou insulina rápida nas últimas 4 horas?',
      kind: FieldKind.yesNo,
      quickReplies: ['Sim', 'Não'],
      dependsOn: MapEntry('symptomType', 'hypo'),
      priority: 2,
    ),
  ],
  // cgm, profile, question and unknown intentionally have no required
  // fields yet — see plan for scope (cgm/profile are stubs; question and
  // unknown are resolved outside the missing-field machinery).
};

const List<FieldSpec> eventContextFields = [
  FieldSpec(
    key: 'occurredWhen',
    question: 'Quando isso aconteceu?',
    kind: FieldKind.option,
    quickReplies: ['Agora', 'Há pouco', 'Mais cedo'],
    optionValues: {
      'agora': 'agora',
      'há pouco': 'há pouco',
      'ha pouco': 'há pouco',
      'mais cedo': 'mais cedo',
    },
    required: false,
  ),
  FieldSpec(
    key: 'location',
    question: 'Onde você estava?',
    kind: FieldKind.option,
    quickReplies: ['Em casa', 'No trabalho/escola', 'Fora de casa'],
    optionValues: {
      'em casa': 'em casa',
      'trabalho': 'trabalho/escola',
      'escola': 'trabalho/escola',
      'fora': 'fora de casa',
    },
    required: false,
  ),
  FieldSpec(
    key: 'contextReason',
    question: 'O que estava acontecendo antes disso?',
    kind: FieldKind.freeText,
    required: false,
  ),
];

class SuggestionEngine {
  static const idleActions = [
    'Registrar glicemia',
    'Registrar refeição',
    'Registrar insulina',
    'Registrar exercício',
    'Estou com sintomas',
    'Tenho uma dúvida',
  ];

  static List<String> forEvent(EventType type) {
    if (type == EventType.glucose || type == EventType.symptoms) {
      return const [
        'Registrar refeição',
        'Registrar insulina',
        'Estou com sintomas',
        'Tenho uma dúvida',
      ];
    }
    if (type == EventType.meal) {
      return const [
        'Registrar insulina',
        'Registrar glicemia',
        'Registrar exercício',
        'Tenho uma dúvida',
      ];
    }
    return idleActions;
  }
}

/// Pure functions answering "what does this event still need?" — the only
/// thing the FSM asks the data table, never "is this a meal?".
class KnowledgeEngine {
  static List<FieldSpec> missingFields(EventType type, Map<String, dynamic> known) {
    final specs = eventDefinitions[type] ?? const <FieldSpec>[];
    final missing = <FieldSpec>[];
    for (final spec in specs) {
      final dependsOn = spec.dependsOn;
      if (dependsOn != null && known[dependsOn.key] != dependsOn.value) {
        continue; // field doesn't apply given what's known so far
      }
      final value = known[spec.key];
      if (spec.required && value == null) missing.add(spec);
    }
    missing.sort((a, b) => a.priority.compareTo(b.priority));
    return missing;
  }

  static bool isComplete(EventType type, Map<String, dynamic> known) =>
      missingFields(type, known).isEmpty;
}

/// Rejects structurally impossible data only; it never evaluates medical care.
class ValidationEngine {
  static EventValidation validate(EventInstance event) {
    for (final key in const ['value', 'dose', 'carbsGrams', 'duration']) {
      final value = event.data[key];
      if (value is num && (!value.isFinite || value < 0)) {
        return EventValidation.invalid('$key must be a finite non-negative number');
      }
    }
    return EventValidation.valid;
  }
}

class EventValidation {
  const EventValidation._({required this.isValid, this.reason});

  final bool isValid;
  final String? reason;

  static const valid = EventValidation._(isValid: true);

  static EventValidation invalid(String reason) =>
      EventValidation._(isValid: false, reason: reason);
}

/// Fixed resolution order for the event stack. `emergency` pre-empts all of
/// this as a global-state gate (never a stack member); `education` is
/// `question`'s resolution state (also never a stack member).
class PriorityEngine {
  static const List<EventType> _rank = [
    EventType.symptoms,
    EventType.glucose,
    EventType.insulin,
    EventType.meal,
    EventType.exercise,
    EventType.illness,
    EventType.ketones,
    EventType.medication,
    EventType.cgm,
    EventType.profile,
    EventType.question,
  ];

  static List<EventInstance> sort(List<EventInstance> stack) {
    final sorted = [...stack];
    sorted.sort((a, b) => _rankOf(a.type).compareTo(_rankOf(b.type)));
    return sorted;
  }

  static int _rankOf(EventType type) {
    final index = _rank.indexOf(type);
    return index == -1 ? _rank.length : index; // unknown sorts last
  }
}

/// Signals the [EmergencyEngine] weighs together — never a single fixed
/// glucose cutoff.
class EmergencyContext {
  const EmergencyContext({
    this.currentGlucose,
    this.activeSymptomType,
    this.recentFastActingInsulin = false,
    this.recentIntenseExercise = false,
    this.hypoglycemiaUnawareness = false,
  });

  final double? currentGlucose;
  final String? activeSymptomType; // 'hypo' | 'hyper' | null
  final bool recentFastActingInsulin;
  final bool recentIntenseExercise;
  final bool hypoglycemiaUnawareness; // from user profile, once available
}

class EmergencyAssessment {
  const EmergencyAssessment({required this.isEmergency, required this.reason, required this.severity});

  final bool isEmergency;
  final String reason;
  final double severity;

  static const none = EmergencyAssessment(isEmergency: false, reason: '', severity: 0);
}

/// Decides whether the current situation warrants pre-empting everything
/// else with the `emergency` global state. This is a first-pass, composed
/// multi-signal score — NOT a fixed "<70 = emergency" rule — and its
/// weights are a placeholder pending clinical review before real use.
class EmergencyEngine {
  EmergencyEngine({RecentEventReader? history}) : _history = history;

  final RecentEventReader? _history;

  Future<EmergencyAssessment> assess(List<EventInstance> stack) async {
    double? glucose;
    String? symptomType;
    for (final event in stack) {
      if (event.type == EventType.glucose && event.data['value'] != null) {
        glucose ??= (event.data['value'] as num).toDouble();
      }
      if (event.type == EventType.symptoms) {
        if (event.data['value'] != null) glucose ??= (event.data['value'] as num).toDouble();
        if (event.data['symptomType'] != null) symptomType ??= event.data['symptomType'] as String;
      }
    }

    final history = _history;
    final recentInsulin = history == null
      ? const <Map<String, dynamic>>[]
      : await history.recentEventsOfType('insulin', const Duration(hours: 2));
    final recentExercise = history == null
      ? const <Map<String, dynamic>>[]
      : await history.recentEventsOfType('exercise', const Duration(hours: 2));

    final context = EmergencyContext(
      currentGlucose: glucose,
      activeSymptomType: symptomType,
      recentFastActingInsulin: recentInsulin.isNotEmpty,
      recentIntenseExercise: recentExercise.any((row) {
        final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        return payload['intensity'] == 'intensa';
      }),
    );
    return _score(context);
  }

  EmergencyAssessment _score(EmergencyContext ctx) {
    double score = 0;
    final reasons = <String>[];

    final glucose = ctx.currentGlucose;
    if (glucose != null) {
      if (glucose < 55) {
        score += 0.6;
        reasons.add('glicemia muito baixa');
      } else if (glucose < 70) {
        score += 0.3;
        reasons.add('glicemia baixa');
      } else if (glucose > 300) {
        score += 0.5;
        reasons.add('glicemia muito alta');
      } else if (glucose > 250) {
        score += 0.25;
        reasons.add('glicemia alta');
      }
    }

    if (ctx.activeSymptomType == 'hypo') {
      score += 0.3;
      reasons.add('sintomas de hipoglicemia');
    } else if (ctx.activeSymptomType == 'hyper') {
      score += 0.2;
      reasons.add('sintomas de hiperglicemia');
    }

    if (ctx.recentFastActingInsulin && ctx.activeSymptomType == 'hypo') {
      score += 0.2;
      reasons.add('insulina rápida recente');
    }
    if (ctx.recentIntenseExercise && (glucose ?? 999) < 100) {
      score += 0.15;
      reasons.add('exercício intenso recente');
    }
    if (ctx.hypoglycemiaUnawareness) {
      score += 0.15;
      reasons.add('histórico de hipoglicemia não percebida');
    }

    return EmergencyAssessment(
      isEmergency: score >= 0.6,
      reason: reasons.join(', '),
      severity: score.clamp(0, 1),
    );
  }
}

/// The emergency global state's own tiny, fixed Q&A — never real-world
/// intervention (no calls/SMS), purely conversational guidance + logging.
const List<FieldSpec> emergencyProtocolFields = [
  FieldSpec(
    key: 'canEatOrDrinkSugar',
    question: 'Você consegue comer ou beber algo com açúcar agora?',
    kind: FieldKind.yesNo,
    quickReplies: ['Sim', 'Não'],
    priority: 0,
  ),
  FieldSpec(
    key: 'hasSomeoneNearby',
    question: 'Você está sozinho(a) ou tem alguém por perto?',
    kind: FieldKind.yesNo,
    quickReplies: ['Tenho alguém', 'Estou sozinho(a)'],
    priority: 1,
  ),
];

double? asDouble(dynamic value) => value == null ? null : (value as num).toDouble();

String formatNumber(num value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

/// Per-event completion messages — data, not FSM control flow (the loop
/// only ever does `eventCompletionMessages[type]?.call(data)`).
final Map<EventType, String Function(Map<String, dynamic> data)> eventCompletionMessages = {
  EventType.meal: (data) {
    final food = data['food'] as String?;
    final grams = asDouble(data['carbsGrams']);
    final foodPart = food != null ? ' ($food)' : '';
    if (grams == null) {
      return 'Registrado: refeição$foodPart sem contagem de carboidratos.';
    }
    return 'Registrado: refeição$foodPart com aproximadamente '
        '${formatNumber(grams)}g de carboidratos.';
  },
  EventType.exercise: (data) {
    final intensity = data['intensity'] as String?;
    return 'Registrado: atividade física ${intensity ?? "não especificada"}. '
        'Fique atento à sua glicemia nas próximas horas — o exercício pode '
        'reduzi-la.';
  },
  EventType.glucose: (data) {
    final value = asDouble(data['value']);
    final usedInsulin = data['usedInsulin'] == true;
    final base = 'Entendido${value != null ? ' — glicemia de ${formatNumber(value)} mg/dL registrada' : ''}.';
    if (usedInsulin) {
      return '$base Como você usou insulina recentemente, fique atento a '
          'sinais de hipoglicemia nas próximas horas.';
    }
    return base;
  },
  EventType.insulin: (data) {
    final dose = asDouble(data['dose']);
    final type = data['insulinType'] as String?;
    return 'Registrado: ${dose != null ? '${formatNumber(dose)} unidades ' : ''}'
        '${type != null ? 'de $type' : 'de insulina'}.';
  },
  EventType.symptoms: (data) {
    if (data['symptomType'] == 'hyper') {
      return 'Glicemia alta por período prolongado pode exigir atenção. Siga '
          'a orientação do seu médico para correção e beba bastante água. Se '
          'sentir mal-estar importante, procure ajuda médica.';
    }
    return 'Se você está com sintomas de hipoglicemia, siga a orientação do '
        'seu médico para tratar (geralmente consumindo um carboidrato de '
        'ação rápida). Se os sintomas forem intensos ou não melhorarem, '
        'procure ajuda médica imediatamente. Isso não substitui orientação '
        'profissional.';
  },
};
