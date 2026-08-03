import 'dart:convert';

/// What actually happened, per the user's own architectural rule: "There
/// are no meal states, glucose states or insulin states. There are only
/// events and missing pieces of information." This is the full universe of
/// things DiabAI can recognize — never a conversational state.
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
enum DiabAIGlobalState {
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
enum EventSource {
  userText,
  quickReply,
  numericInput,
  semanticParser,
  cgm,
  system
}

/// Each event has one lifecycle position at a time.
enum EventStatus {
  queued,
  waitingInformation,
  validating,
  stored,
  discarded,
  escalated,
}

/// Canonical facts that the persisted Mermaid specification must mirror.
class FsmContract {
  static const activeStates = [
    DiabAIGlobalState.idle,
    DiabAIGlobalState.parsing,
    DiabAIGlobalState.prioritizing,
    DiabAIGlobalState.waitingInformation,
    DiabAIGlobalState.enrichingContext,
    DiabAIGlobalState.validating,
    DiabAIGlobalState.storing,
    DiabAIGlobalState.clarification,
    DiabAIGlobalState.resuming,
    DiabAIGlobalState.emergency,
    DiabAIGlobalState.onboarding,
    DiabAIGlobalState.education,
  ];

  static const stubStates = [
    DiabAIGlobalState.learningUser,
  ];

  static const initializationProfileFields = [
    'idioma',
    'nome',
    'peso',
    'tipoDiabetes',
    'tempoDiagnostico',
    'insulinas',
  ];
  static const initializationEntryState = DiabAIGlobalState.onboarding;
  static const initializationExitState = DiabAIGlobalState.idle;
  static const initializationModelGate = 'model-ready-before-onboarding';
  static const initializationModelFailure = 'wait-and-retry';

  static const priority = [
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
    EventType.unknown,
  ];

  static const lifecycleEdges = [
    'queued->waitingInformation',
    'waitingInformation->validating',
    'queued->validating',
    'validating->stored',
    'validating->discarded',
    'queued->discarded',
    'queued->escalated',
    'waitingInformation->escalated',
    'escalated->waitingInformation',
    'escalated->validating',
  ];

  static const semanticInterpreterInputs = ['free-text'];
  static const semanticInterpreterOutputs = [
    'event-candidates',
    'entities',
    'confidence',
  ];
  static const semanticInterpreterMinimumConfidence = 0.5;
  static const semanticInterpreterChangesGlobalState = false;
  static const semanticInterpreterChangesLifecycle = false;
  static const semanticInterpreterDoesMedicalReasoning = false;

  static const nunoAppliesTo = 'unknown-intent-free-reply';
  static const nunoInteractionMode = 'free';
  static const nunoPersonaName = 'Nuno';
  static const nunoTone = [
    'calm',
    'objective',
    'non-alarmist',
    'non-childish',
  ];
  static const nunoExplainsOnRequest = true;
  static const nunoEmergencyBehavior = 'fast-and-decisive';
  static const nunoDoesMedicalReasoning = false;
  static const nunoInsulinDoseCalculation = false;
  static const nunoDiagnosis = false;
  static const nunoChangesGlobalState = false;
  static const nunoChangesLifecycle = false;
  static const nunoUsesRecentContext = true;
  static const nunoContextWindowTurns = 3;

  static const cgmAskedDuringOnboarding = true;
  static const cgmProfileFields = [
    'cgmUsaServico',
    'cgmProvider',
    'cgmLibreLinkUpConectado',
  ];
  static const cgmDirectIntegrationProviders = [
    'freestyle libre 2',
    'freestyle libre 2 plus',
    'freestyle libre 3',
  ];
  static const cgmIntegrationService = 'librelinkup';
  static const cgmCredentialStorage = 'device-secure-storage-only';
  static const cgmSyncIntervalSeconds = 60;
  static const cgmSyncedReadingsEventType = 'glucose';
  static const cgmSyncedReadingsSource = 'cgm';
  static const cgmChangesGlobalState = false;
  static const cgmChangesLifecycle = false;
  static const cgmEmergencyImpact = false;
  static const cgmPriorityImpact = false;
  static const cgmDoesMedicalReasoning = false;

  static const interactionModes = ['free', 'guided'];
  static const freeModeInput = 'conversation-text-to-semantic-interpreter';
  static const guidedModeInput = 'field-specific-controls';
  static const guidedModeExit = 'preserve-stack-return-free-input';
  static const interactionModesChangeGlobalState = false;
  static const interactionModesChangeLifecycle = false;

  static const guidedEventModules = [
    EventType.glucose,
    EventType.insulin,
    EventType.meal,
    EventType.exercise,
    EventType.illness,
    EventType.ketones,
    EventType.medication,
    EventType.symptoms,
  ];
  static const supportModules = [
    'onboarding',
    'emergency',
    'event-context',
    'profile',
    'education',
    'cgm',
  ];
  static const moduleIdentity = 'canonical-event-type-or-support-id';
  static const moduleTitleSource = 'localized-module-catalog';
  static const moduleGuidedControls = 'field-spec-kind-and-canonical-option-id';
  static const moduleSemanticRouting = 'llm-event-candidates-only';
  static const moduleKernelHumanLanguage = false;
  static const modulesChangeGlobalState = false;
  static const modulesChangeLifecycle = false;

  static const mealFields = [
    'mealStatus',
    'carbsKnown',
    'carbsGrams',
    'foodDetailsOptIn',
    'foodDetails',
    'plannedFoods',
    'plannedCarbsKnown',
    'plannedCarbsGrams',
  ];
  static const mealRecordedPath = [
    'mealStatus=alreadyEaten',
    'carbsKnown',
    'carbsGrams?',
    'foodDetailsOptIn',
    'foodDetails?',
    'optional-context',
    'stored',
  ];
  static const mealPlannedPath = [
    'mealStatus=planned',
    'plannedFoods',
    'plannedCarbsKnown',
    'plannedCarbsGrams?',
    'optional-context',
    'stored',
  ];

  static const temporalWindows = {
    'last15Minutes': 15,
    'last1Hour': 60,
    'last4Hours': 240,
    'last12Hours': 720,
    'last24Hours': 1440,
  };

  static const temporalEventTypes = [
    EventType.meal,
    EventType.exercise,
    EventType.insulin,
    EventType.symptoms,
    EventType.glucose,
  ];

  static const temporalConsumers = ['emergency', 'priority', 'knowledge'];
  static const temporalTimestamp = 'createdAt';
  static const timeEngineChangesGlobalState = false;
  static const timeEngineChangesLifecycle = false;

  static const profileFields = [
    'name',
    'email',
    'photoUrl',
    'diabetesType',
    'weightKg',
    'heightCm',
    'ageYears',
    'sex',
    'cgm',
    'insulinPump',
    'insulinTypes',
    'insulinCarbRatio',
    'correctionFactor',
    'hypoglycemiaUnawareness',
    'diagnosisDuration',
    'knowledgeLevel',
    'interactionMode',
  ];

  static const profileSources = [
    'authenticated-user',
    'current-profile',
    'event-stack',
    'sqlite-history',
  ];
  static const profileOutputs = [
    'updated-profile',
    'completeness-score',
    'missing-information',
    'confidence-scores',
  ];
  static const profileConsumers = [
    'emergency',
    'priority',
    'knowledge',
    'profile-view',
  ];
  static const profilePersistence = 'sqlite-profile-snapshot';
  static const profileEngineChangesGlobalState = false;
  static const profileEngineChangesLifecycle = false;
  static const profileEngineAsksQuestions = false;
  static const profileEngineDoesMedicalReasoning = false;
  static const profileLifecycleSteps = [
    'observed',
    'merged',
    'persisted',
    'retrieved',
    'photo-selected',
    'projected',
    'rendered',
  ];
  static const profileViewGeneralFields = [
    'name',
    'email',
    'ageYears',
    'sex',
    'weightKg',
    'heightCm',
  ];
  static const profileViewPriorityGroups = [
    [
      'diabetesType',
      'cgm',
      'insulinPump',
      'insulinTypes',
    ],
    [
      'insulinCarbRatio',
      'correctionFactor',
      'hypoglycemiaUnawareness',
      'diagnosisDuration',
    ],
    [
      'knowledgeLevel',
      'interactionMode',
    ],
    [
      'exerciseProfile',
      'mealPatterns',
      'insulinUsagePatterns',
      'learnedFacts',
    ],
  ];
  static const profileViewKnownOnly = true;
  static const profileViewDynamic = true;
  static const profileViewSort = 'general-then-priority-ascending';
  static const profileViewAvatarSources = [
    'authenticated-photo',
    'local-photo',
    'picker-placeholder',
  ];
  static const profileViewCompleteness = 'always-render';
  static const profileCompletenessScore =
      'priority-weighted-known-health-facts';
  static const profileCompletenessFields = [
    'diabetesType',
    'weightKg',
    'heightCm',
    'ageYears',
    'sex',
    'cgm',
    'insulinPump',
    'insulinTypes',
    'insulinCarbRatio',
    'correctionFactor',
    'hypoglycemiaUnawareness',
    'diagnosisDuration',
    'knowledgeLevel',
    'interactionMode',
  ];
  static const profileCompletenessPriorityGroups = [
    [
      'diabetesType',
      'weightKg',
      'cgm',
      'insulinPump',
      'insulinTypes',
    ],
    [
      'insulinCarbRatio',
      'correctionFactor',
      'hypoglycemiaUnawareness',
      'diagnosisDuration',
    ],
    [
      'ageYears',
      'sex',
      'heightCm',
      'knowledgeLevel',
      'interactionMode',
    ],
  ];
  static const profileCompletenessWeights = [12, 8, 4];
  static const profileViewChangesGlobalState = false;
  static const profileViewChangesLifecycle = false;
  static const profileViewAsksQuestions = false;
  static const profileViewDoesMedicalReasoning = false;
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
  final DiabAIGlobalState globalState;
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

/// Read-only temporal facts derived from the current stack and stored events.
abstract interface class TemporalContext {
  int count(EventType type, Duration within);
  bool has(EventType type, Duration within);
  bool hasFieldValue(
    EventType type,
    String field,
    Object value,
    Duration within,
  );
}

/// Builds a [TemporalContext] once per FSM turn without coupling engines to
/// a storage implementation.
abstract interface class TemporalContextProvider {
  Future<TemporalContext> buildContext(List<EventInstance> stack);
}

/// Read-only facts about the user, assembled passively from profile data and
/// normal conversation. Consumers may inspect it but must not turn missing
/// facts into new FSM states.
abstract interface class ProfileContext {
  Object? value(String field);
  double confidence(String field);
  int get completenessScore;
  List<String> get missingInformation;
}

/// Local persistence boundary for the evolving profile snapshot.
abstract interface class ProfileSnapshotGateway {
  Future<Map<String, dynamic>?> loadProfileSnapshot();
  Future<void> saveProfileSnapshot(Map<String, dynamic> snapshot);
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
    FieldSpec(
      key: 'measurementContext',
      question: 'Essa medição foi em jejum, depois de comer, ou aleatória?',
      kind: FieldKind.option,
      quickReplies: ['Jejum', 'Pós-refeição', 'Aleatória'],
      optionValues: {
        'jejum': 'jejum',
        'pós-refeição': 'pos-refeicao',
        'pos-refeicao': 'pos-refeicao',
        'pós refeição': 'pos-refeicao',
        'aleatóri': 'aleatoria',
        'aleatori': 'aleatoria',
      },
      priority: 2,
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
    FieldSpec(
      key: 'insulinType',
      question: 'Qual tipo de insulina você aplicou?',
      kind: FieldKind.option,
      quickReplies: ['Rápida/Ultrarrápida', 'Basal/Lenta', 'Pré-misturada'],
      optionValues: {
        'rápida': 'rapida',
        'rapida': 'rapida',
        'ultrarrápida': 'rapida',
        'ultrarrapida': 'rapida',
        'basal': 'basal',
        'lenta': 'basal',
        'pré-mistura': 'pre-misturada',
        'pre-mistura': 'pre-misturada',
      },
      priority: 1,
    ),
    FieldSpec(
      key: 'doseContext',
      question: 'Essa dose foi para corrigir a glicemia, cobrir uma refeição, ou basal/rotina?',
      kind: FieldKind.option,
      quickReplies: ['Correção', 'Refeição', 'Basal/rotina'],
      optionValues: {
        'correç': 'correcao',
        'correc': 'correcao',
        'refeiç': 'refeicao',
        'refeic': 'refeicao',
        'basal': 'basal-rotina',
        'rotina': 'basal-rotina',
      },
      priority: 2,
    ),
  ],
  EventType.meal: const [
    FieldSpec(
      key: 'mealStatus',
      question: 'Você já se alimentou ou está planejando essa refeição?',
      kind: FieldKind.option,
      quickReplies: ['Já comi', 'Ainda não comi'],
      optionValues: {
        'já comi': 'alreadyEaten',
        'ja comi': 'alreadyEaten',
        'ainda não': 'planned',
        'ainda nao': 'planned',
      },
      priority: 0,
    ),
    FieldSpec(
      key: 'carbsKnown',
      question: 'Você sabe aproximadamente quantos gramas de carboidratos '
          'tinha essa refeição?',
      kind: FieldKind.yesNo,
      quickReplies: ['Sim, sei', 'Não sei'],
      dependsOn: MapEntry('mealStatus', 'alreadyEaten'),
      priority: 1,
    ),
    FieldSpec(
      key: 'carbsGrams',
      question: 'Quantos gramas de carboidratos, aproximadamente?',
      kind: FieldKind.number,
      numericInputHint: 'Gramas de carboidrato',
      dependsOn: MapEntry('carbsKnown', true),
      priority: 2,
    ),
    FieldSpec(
      key: 'foodDetailsOptIn',
      question: 'Quer detalhar o que você comeu para registrar como contexto?',
      kind: FieldKind.option,
      quickReplies: ['Quero detalhar', 'Não agora'],
      optionValues: {
        'quero detalhar': 'yes',
        'não agora': 'no',
        'nao agora': 'no',
      },
      dependsOn: MapEntry('mealStatus', 'alreadyEaten'),
      priority: 3,
    ),
    FieldSpec(
      key: 'foodDetails',
      question: 'O que você comeu?',
      kind: FieldKind.freeText,
      dependsOn: MapEntry('foodDetailsOptIn', 'yes'),
      priority: 4,
    ),
    FieldSpec(
      key: 'plannedFoods',
      question: 'Quais alimentos você pretende consumir?',
      kind: FieldKind.freeText,
      dependsOn: MapEntry('mealStatus', 'planned'),
      priority: 1,
    ),
    FieldSpec(
      key: 'plannedCarbsKnown',
      question: 'Você tem uma estimativa dos carboidratos dessa refeição?',
      kind: FieldKind.yesNo,
      quickReplies: ['Sim, tenho', 'Ainda não'],
      dependsOn: MapEntry('mealStatus', 'planned'),
      priority: 2,
    ),
    FieldSpec(
      key: 'plannedCarbsGrams',
      question: 'Quantos gramas de carboidratos você estima, aproximadamente?',
      kind: FieldKind.number,
      numericInputHint: 'Estimativa de carboidratos (g)',
      dependsOn: MapEntry('plannedCarbsKnown', true),
      priority: 3,
    ),
  ],
  EventType.exercise: const [
    FieldSpec(
      key: 'intensity',
      question: 'Que bom que você se exercitou! A atividade foi:',
      kind: FieldKind.option,
      quickReplies: ['Leve', 'Moderada', 'Intensa'],
      optionValues: {
        'leve': 'leve',
        'moderad': 'moderada',
        'intens': 'intensa'
      },
      priority: 0,
    ),
    FieldSpec(
      key: 'duration',
      question: 'Quantos minutos durou o exercício, aproximadamente?',
      kind: FieldKind.number,
      numericInputHint: 'Duração (minutos)',
      priority: 1,
    ),
    FieldSpec(
      key: 'activityType',
      question: 'Qual foi a atividade (ex: caminhada, corrida, musculação)?',
      kind: FieldKind.freeText,
      priority: 2,
    ),
  ],
  EventType.illness: const [
    FieldSpec(
      key: 'illnessType',
      question: 'O que você está sentindo ou qual condição está enfrentando?',
      kind: FieldKind.freeText,
    ),
    FieldSpec(
      key: 'severity',
      question: 'Como você classificaria a intensidade: leve, moderada, ou grave?',
      kind: FieldKind.option,
      quickReplies: ['Leve', 'Moderada', 'Grave'],
      optionValues: {
        'leve': 'leve',
        'moderad': 'moderada',
        'grave': 'grave',
      },
      priority: 1,
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
    FieldSpec(
      key: 'measurementMethod',
      question: 'Como foi feita a medição: urina ou sangue?',
      kind: FieldKind.option,
      quickReplies: ['Urina', 'Sangue'],
      optionValues: {
        'urina': 'urina',
        'sangue': 'sangue',
      },
      priority: 2,
    ),
  ],
  EventType.medication: const [
    FieldSpec(
      key: 'medicationName',
      question: 'Qual medicamento você tomou ou quer registrar?',
      kind: FieldKind.freeText,
    ),
    FieldSpec(
      key: 'dose',
      question: 'Qual foi a dose ou quantidade?',
      kind: FieldKind.number,
      numericInputHint: 'Dose/quantidade',
      priority: 1,
    ),
    FieldSpec(
      key: 'reason',
      question: 'Para que você tomou esse medicamento?',
      kind: FieldKind.freeText,
      priority: 2,
    ),
  ],
  EventType.symptoms: const [
    FieldSpec(
      key: 'symptomType',
      question: 'Isso parece mais com sintomas de açúcar baixo ou açúcar alto?',
      kind: FieldKind.option,
      quickReplies: ['Baixo (hipoglicemia)', 'Alto (hiperglicemia)'],
      optionValues: {
        'baixo': 'hypo',
        'hipo': 'hypo',
        'alto': 'hyper',
        'hiper': 'hyper'
      },
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
    FieldSpec(
      key: 'severity',
      question: 'Como você classificaria a intensidade: leve, moderada, ou intensa?',
      kind: FieldKind.option,
      quickReplies: ['Leve', 'Moderada', 'Intensa'],
      optionValues: {
        'leve': 'leve',
        'moderad': 'moderada',
        'intens': 'intensa',
      },
      priority: 3,
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
  static List<FieldSpec> missingFields(
      EventType type, Map<String, dynamic> known) {
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

  /// Missing profile facts remain knowledge data. The kernel decides whether
  /// to surface them; ProfileEngine itself never asks for them.
  static List<String> missingProfileInformation(ProfileContext profile) =>
      profile.missingInformation;
}

/// Rejects structurally impossible data only; it never evaluates medical care.
class ValidationEngine {
  static EventValidation validate(EventInstance event) {
    for (final key in const [
      'value',
      'dose',
      'carbsGrams',
      'plannedCarbsGrams',
      'duration',
    ]) {
      final value = event.data[key];
      if (value is num && (!value.isFinite || value < 0)) {
        return EventValidation.invalid(
            '$key must be a finite non-negative number');
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
  static List<EventInstance> sort(List<EventInstance> stack) {
    final sorted = [...stack];
    sorted.sort((a, b) => _rankOf(a.type).compareTo(_rankOf(b.type)));
    return sorted;
  }

  static int _rankOf(EventType type) {
    return FsmContract.priority.indexOf(type);
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
  const EmergencyAssessment({
    required this.isEmergency,
    required this.reason,
    required this.severity,
    this.usedTemporalContext = false,
  });

  final bool isEmergency;
  final String reason;
  final double severity;
  final bool usedTemporalContext;

  static const none =
      EmergencyAssessment(isEmergency: false, reason: '', severity: 0);
}

/// Decides whether the current situation warrants pre-empting everything
/// else with the `emergency` global state. This is a first-pass, composed
/// multi-signal score — NOT a fixed "<70 = emergency" rule — and its
/// weights are a placeholder pending clinical review before real use.
class EmergencyEngine {
  EmergencyEngine({
    RecentEventReader? history,
    TemporalContextProvider? temporalContextProvider,
  })  : _history = history,
        _temporalContextProvider = temporalContextProvider;

  static const scoreThreshold = 0.6;
  static const signals = [
    'glucose',
    'symptomType',
    'recentInsulin',
    'recentIntenseExercise',
    'hypoglycemiaUnawareness',
  ];

  final RecentEventReader? _history;
  final TemporalContextProvider? _temporalContextProvider;

  Future<EmergencyAssessment> assess(
    List<EventInstance> stack, {
    ProfileContext? profileContext,
  }) async {
    double? glucose;
    String? symptomType;
    for (final event in stack) {
      if (event.type == EventType.glucose && event.data['value'] != null) {
        glucose ??= asDouble(event.data['value']);
      }
      if (event.type == EventType.symptoms) {
        if (event.data['value'] != null) {
          glucose ??= asDouble(event.data['value']);
        }
        if (event.data['symptomType'] != null) {
          symptomType ??= event.data['symptomType'] as String;
        }
      }
    }

    final temporalContext = await _temporalContextProvider?.buildContext(stack);
    final history = _history;
    final recentInsulin = temporalContext == null && history != null
        ? await history.recentEventsOfType('insulin', const Duration(hours: 4))
        : const <Map<String, dynamic>>[];
    final recentExercise = temporalContext == null && history != null
        ? await history.recentEventsOfType('exercise', const Duration(hours: 4))
        : const <Map<String, dynamic>>[];
    final recentFastActingInsulin = temporalContext?.has(
          EventType.insulin,
          const Duration(hours: 4),
        ) ??
        recentInsulin.isNotEmpty;
    final recentIntenseExercise = temporalContext?.hasFieldValue(
          EventType.exercise,
          'intensity',
          'intensa',
          const Duration(hours: 4),
        ) ??
        recentExercise.any((row) {
          final payload =
              jsonDecode(row['payload'] as String) as Map<String, dynamic>;
          return payload['intensity'] == 'intensa';
        });

    final context = EmergencyContext(
      currentGlucose: glucose,
      activeSymptomType: symptomType,
      recentFastActingInsulin: recentFastActingInsulin,
      recentIntenseExercise: recentIntenseExercise,
      hypoglycemiaUnawareness:
          profileContext?.value('hypoglycemiaUnawareness') == true &&
              profileContext!.confidence('hypoglycemiaUnawareness') >= 0.5,
    );
    return _score(context, usedTemporalContext: temporalContext != null);
  }

  EmergencyAssessment _score(
    EmergencyContext ctx, {
    required bool usedTemporalContext,
  }) {
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
      } else if (glucose < 90) {
        score += 0.2;
        reasons.add('glicemia em faixa de atenção');
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

    if (ctx.recentFastActingInsulin &&
        (ctx.activeSymptomType == 'hypo' || (glucose ?? 999) < 90)) {
      score += 0.25;
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
      isEmergency: score >= scoreThreshold,
      reason: reasons.join(', '),
      severity: score.clamp(0, 1),
      usedTemporalContext: usedTemporalContext,
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

double? asDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.replaceAll(',', '.'));
  return null;
}

String formatNumber(num value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toString();

/// Per-event completion messages — data, not FSM control flow (the loop
/// only ever does `eventCompletionMessages[type]?.call(data)`).
final Map<EventType, String Function(Map<String, dynamic> data)>
    eventCompletionMessages = {
  EventType.meal: (data) {
    final isPlanned = data['mealStatus'] == 'planned';
    final food = (isPlanned ? data['plannedFoods'] : data['foodDetails'])
        as String?;
    final grams = asDouble(data['carbsGrams']);
    final foodPart = food != null ? ' ($food)' : '';
    if (isPlanned) {
      final plannedGrams = asDouble(data['plannedCarbsGrams']);
      if (plannedGrams == null) {
        return 'Planejamento registrado: refeição$foodPart sem estimativa '
            'de carboidratos.';
      }
      return 'Planejamento registrado: refeição$foodPart com estimativa '
          'de ${formatNumber(plannedGrams)}g de carboidratos.';
    }
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
    final base =
        'Entendido${value != null ? ' — glicemia de ${formatNumber(value)} mg/dL registrada' : ''}.';
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
