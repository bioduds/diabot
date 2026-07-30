import 'events.dart';
import 'initialization.dart';
import 'nlu.dart';
import 'profile_engine.dart';
import 'user_profile.dart';

/// A single response from [ConversationOrchestrator]: fixed, human-authored
/// text (never LLM free-text, except the one FSM-approved exception in
/// [DiabotGlobalState.education]) plus optional quick-reply options and/or
/// a numeric input hint.
class OrchestratorReply {
  final String text;
  final List<String>? quickReplies;
  final String? numericInputHint;

  const OrchestratorReply(
    this.text, {
    this.quickReplies,
    this.numericInputHint,
  });
}

/// Delegates a `question` event to RAG/LLM for a free-text answer — the
/// ONLY thing the LLM is ever allowed to say directly to the user, and
/// only because the FSM itself decided to enter [DiabotGlobalState.education]
/// and explicitly asked for it.
typedef EducationAnswer = Future<String> Function(String question);

/// DIABOT's finite state machine.
///
/// Governing rule: "There are no meal states, glucose states or insulin
/// states. There are only events and missing pieces of information." This
/// class never branches on event identity except to look up generic data
/// ([eventDefinitions], [eventCompletionMessages]) — all control flow is
/// generic over [DiabotGlobalState] and [FieldKind].
///
/// Pipeline: user input -> parser (LLM, multi-event) -> event stack ->
/// emergency gate -> priority engine -> knowledge engine -> next question
/// or store -> idle.
class ConversationOrchestrator {
  ConversationOrchestrator({
    this.storeGateway,
    this.onEducationRequest,
    InitializationModule? initializationModule,
    EmergencyEngine? emergencyEngine,
    ProfileEngine? profileEngine,
  })  : _initializationModule = initializationModule ?? InitializationModule(),
        _emergencyEngine = emergencyEngine ?? EmergencyEngine(),
        _profileEngine = profileEngine ?? ProfileEngine(
          snapshotGateway: storeGateway is ProfileSnapshotGateway
            ? storeGateway as ProfileSnapshotGateway
              : null,
        );

  final FsmStoreGateway? storeGateway;
  final EducationAnswer? onEducationRequest;
  final InitializationModule _initializationModule;
  final EmergencyEngine _emergencyEngine;
  final ProfileEngine _profileEngine;

  static const Map<String, EventType> _clarificationShortcuts = {
    'uma refeição': EventType.meal,
    'exercício': EventType.exercise,
    'minha glicemia': EventType.glucose,
    'uma dose de insulina': EventType.insulin,
    'registrar glicemia': EventType.glucose,
    'registrar refeição': EventType.meal,
    'registrar insulina': EventType.insulin,
    'registrar exercício': EventType.exercise,
    'estou com sintomas': EventType.symptoms,
    'registrar doença': EventType.illness,
    'registrar cetonas': EventType.ketones,
    'registrar medicamento': EventType.medication,
  };

  static const List<String> _clarificationQuickReplies = [
    'Uma refeição',
    'Exercício',
    'Minha glicemia',
    'Uma dose de insulina',
  ];

  DiabotGlobalState _state = DiabotGlobalState.idle;
  final List<EventInstance> _eventStack = [];
  String? _pendingFieldKey;
  int _contextFieldIndex = 0;
  bool _awaitingEducationQuestion = false;

  String _emergencyReason = '';
  final Map<String, dynamic> _emergencyData = {};
  ProfileContext? _profileContext;

  DiabotGlobalState get state => _state;

  /// Starts the first-login profile collection after the local model is
  /// ready. The caller is responsible for only invoking it when no saved
  /// profile exists.
  Future<OrchestratorReply> beginOnboarding({
    required UserProfile profile,
    required String deviceLanguage,
    String? accountDisplayName,
  }) async {
    _state = DiabotGlobalState.onboarding;
    final reply = await _initializationModule.begin(
      profile: profile,
      deviceLanguage: deviceLanguage,
      accountDisplayName: accountDisplayName,
    );
    return _onboardingReply(reply);
  }

  /// Entry point for a new piece of user input (typed, transcribed, or a
  /// tapped quick-reply label / numeric entry — all treated the same way).
  Future<OrchestratorReply> respond(
    String rawText,
    IntentClassifier? classifier,
  ) async {
    if (_state == DiabotGlobalState.onboarding) {
      return _onboardingReply(await _initializationModule.respond(rawText));
    }

    if (_state == DiabotGlobalState.emergency) {
      if (_tryFillEmergencyField(rawText)) return _resolveStack();
      return OrchestratorReply(
        _currentEmergencyQuestion()?.question ?? 'Você está bem agora?',
        quickReplies: _currentEmergencyQuestion()?.quickReplies,
      );
    }

    if (_state == DiabotGlobalState.education &&
        _awaitingEducationQuestion) {
      _awaitingEducationQuestion = false;
      _eventStack.add(EventInstance(
        type: EventType.question,
        data: {'raw_text': rawText},
        source: EventSource.quickReply,
      ));
      return _resolveStack();
    }

    if (_state == DiabotGlobalState.enrichingContext &&
        _eventStack.isNotEmpty) {
      final reply = await _tryFillContext(rawText);
      if (reply != null) return reply;
    }

    if (_pendingFieldKey != null && _eventStack.isNotEmpty) {
      final filled =
          _tryFillPendingField(_eventStack.first, _pendingFieldKey!, rawText);
      if (filled) {
        _pendingFieldKey = null;
        return _resolveStack();
      }
      // Shape mismatch: this is a topic switch. The pending event stays
      // queued (never discarded) and the raw text is reprocessed as new
      // input below.
    }

    _state = DiabotGlobalState.parsing;
    await _parseAndPushEvents(rawText, classifier);
    if (_awaitingEducationQuestion) {
      return const OrchestratorReply('Qual é sua dúvida?');
    }
    return _resolveStack();
  }

  OrchestratorReply _onboardingReply(InitializationReply reply) {
    if (_initializationModule.isComplete) {
      _state = DiabotGlobalState.idle;
    }
    return OrchestratorReply(reply.text, quickReplies: reply.quickReplies);
  }

  Future<void> _parseAndPushEvents(
    String rawText,
    IntentClassifier? classifier,
  ) async {
    if (rawText.trim().toLowerCase() == 'tenho uma dúvida') {
      _state = DiabotGlobalState.education;
      _awaitingEducationQuestion = true;
      return;
    }

    final shortcut = _clarificationShortcuts[rawText.trim().toLowerCase()];
    if (shortcut != null) {
      _eventStack.add(EventInstance(
        type: shortcut,
        source: EventSource.quickReply,
      ));
      return;
    }

    final bareNumber = _extractBareNumber(rawText);
    if (bareNumber != null) {
      _eventStack.add(EventInstance(
        type: EventType.glucose,
        data: {'value': bareNumber},
        source: EventSource.numericInput,
      ));
      return;
    }

    if (classifier == null) {
      _eventStack.add(EventInstance(type: EventType.unknown));
      return;
    }

    final extraction = await classifier.classify(rawText);
    if (extraction.events.isEmpty || extraction.confidence < 0.5) {
      _eventStack.add(EventInstance(type: EventType.unknown));
      return;
    }

    final entities = _normalizeEntities(extraction.entities);
    for (final type in extraction.events) {
      _eventStack.add(EventInstance(
        type: type,
        data: {
          ...entities,
          'raw_text': rawText,
          '_parserConfidence': extraction.confidence,
        },
        source: EventSource.semanticParser,
      ));
    }
  }

  /// Maps the parser's fixed entity keys to the internal field keys used
  /// by [eventDefinitions] — glue between the LLM's output shape and the
  /// generic knowledge engine, not event-specific control flow.
  Map<String, dynamic> _normalizeEntities(Map<String, dynamic> raw) {
    final out = <String, dynamic>{};
    if (raw['glucose'] != null) out['value'] = raw['glucose'];
    if (raw['food'] != null) out['food'] = raw['food'];
    if (raw['carbs_grams'] != null) {
      out['carbsGrams'] = raw['carbs_grams'];
      out['carbsKnown'] = true;
    }
    if (raw['duration'] != null) out['duration'] = raw['duration'];
    if (raw['intensity'] != null) out['intensity'] = raw['intensity'];
    if (raw['insulin_type'] != null) out['insulinType'] = raw['insulin_type'];
    if (raw['dose'] != null) out['dose'] = raw['dose'];
    if (raw['symptom_type'] != null) out['symptomType'] = raw['symptom_type'];
    const profileEntityKeys = {
      'profile_diabetes_type': 'diabetesType',
      'profile_weight_kg': 'weightKg',
      'profile_height_cm': 'heightCm',
      'profile_age_years': 'ageYears',
      'profile_sex': 'sex',
      'profile_cgm': 'cgm',
      'profile_insulin_pump': 'insulinPump',
      'profile_insulin_carb_ratio': 'insulinCarbRatio',
      'profile_correction_factor': 'correctionFactor',
      'profile_hypoglycemia_unawareness': 'hypoglycemiaUnawareness',
      'profile_diagnosis_duration': 'diagnosisDuration',
      'profile_knowledge_level': 'knowledgeLevel',
      'profile_interaction_mode': 'interactionMode',
    };
    for (final entry in profileEntityKeys.entries) {
      if (raw[entry.key] != null) out[entry.value] = raw[entry.key];
    }
    return out;
  }

  /// The FSM's central loop: emergency gate (checked once per new turn,
  /// never re-checked mid-cascade to avoid re-triggering on the same
  /// still-unresolved signal) -> stack processing.
  Future<OrchestratorReply> _resolveStack() async {
    if (_state == DiabotGlobalState.emergency) {
      return _resolveEmergency();
    }

    _profileContext = (await _profileEngine.enrich(_eventStack)).profile;
    final assessment = await _emergencyEngine.assess(
      _eventStack,
      profileContext: _profileContext,
    );
    if (assessment.isEmergency) {
      await _markStackEscalated(assessment.reason);
      _state = DiabotGlobalState.emergency;
      _emergencyReason = assessment.reason;
      _emergencyData.clear();
      final reply = await _resolveEmergency();
      return OrchestratorReply(
        '${_emergencyIntro(assessment.reason, assessment.usedTemporalContext)}\n\n${reply.text}',
        quickReplies: reply.quickReplies,
        numericInputHint: reply.numericInputHint,
      );
    }

    return _processStack();
  }

  /// Priority engine -> knowledge engine -> ask/store, recursing until the
  /// stack empties or a question needs to be asked. Never re-checks the
  /// emergency gate (that only happens once per turn, in [_resolveStack]).
  Future<OrchestratorReply> _processStack() async {
    if (_eventStack.isEmpty) {
      return _idleReply();
    }

    _state = DiabotGlobalState.prioritizing;
    final sorted = PriorityEngine.sort(_eventStack);
    _eventStack
      ..clear()
      ..addAll(sorted);
    final active = _eventStack.first;

    if (active.type == EventType.question) {
      await _transition(active, EventStatus.validating);
      _eventStack.removeAt(0);
      _state = DiabotGlobalState.education;
      final question = active.data['raw_text'] as String? ?? '';
      final answer = await _resolveEducation(question);
      _state = DiabotGlobalState.idle;
      return _continueAfter(answer);
    }

    if (active.type == EventType.unknown) {
      await _transition(
        active,
        EventStatus.discarded,
        reason: 'parser could not produce a valid event',
      );
      _eventStack.removeAt(0);
      _state = DiabotGlobalState.clarification;
      return const OrchestratorReply(
        'Não entendi bem. Sobre o que você quer falar?',
        quickReplies: _clarificationQuickReplies,
      );
    }

    final missing = KnowledgeEngine.missingFields(active.type, active.data);
    if (missing.isEmpty) {
        if (active.type != EventType.profile &&
          active.data['_contextHandled'] != true) {
        _state = DiabotGlobalState.enrichingContext;
        _pendingFieldKey = '_contextOptIn';
        return const OrchestratorReply(
          'Quer registrar também quando, onde e o que estava acontecendo?',
          quickReplies: ['Adicionar contexto', 'Continuar sem contexto'],
        );
      }
      _state = DiabotGlobalState.validating;
      await _transition(active, EventStatus.validating);
      final validation = ValidationEngine.validate(active);
      if (!validation.isValid) {
        await _transition(
          active,
          EventStatus.discarded,
          reason: validation.reason,
        );
        _eventStack.removeAt(0);
        _state = DiabotGlobalState.clarification;
        return const OrchestratorReply(
          'Não consegui registrar esse dado porque ele não é válido. '
          'Pode informar novamente?',
        );
      }
      _state = DiabotGlobalState.storing;
      await _store(active);
      _eventStack.removeAt(0);
      final message = eventCompletionMessages[active.type]?.call(active.data) ??
          'Registrado.';
      if (_eventStack.isEmpty) {
        return _idleReply(message: message, completed: active.type);
      }
      return _continueAfter(message);
    }

    final field = missing.first;
    _pendingFieldKey = field.key;
    _state = DiabotGlobalState.waitingInformation;
    await _transition(
      active,
      EventStatus.waitingInformation,
      reason: 'missing ${field.key}',
    );
    return OrchestratorReply(
      field.question,
      quickReplies: field.quickReplies,
      numericInputHint: field.numericInputHint,
    );
  }

  /// Continues processing the rest of the stack (no emergency re-check)
  /// and prefixes its reply with [message] (e.g. a just-completed event's
  /// confirmation text before asking about the next one).
  Future<OrchestratorReply> _continueAfter(String message) async {
    final next = await _processStack();
    return OrchestratorReply(
      '$message\n\n${next.text}',
      quickReplies: next.quickReplies,
      numericInputHint: next.numericInputHint,
    );
  }

  OrchestratorReply _idleReply({String? message, EventType? completed}) {
    _state = DiabotGlobalState.idle;
    final intro = message == null
        ? 'O que você quer fazer agora?'
        : '$message\n\nEstá tudo bem por enquanto. O que você quer fazer agora?';
    return OrchestratorReply(
      intro,
      quickReplies: completed == null
          ? SuggestionEngine.idleActions
          : SuggestionEngine.forEvent(completed),
    );
  }

  Future<String> _resolveEducation(String question) async {
    final answerFn = onEducationRequest;
    if (answerFn == null || question.trim().isEmpty) {
      return 'Ainda não consigo responder perguntas agora.';
    }
    try {
      return await answerFn(question);
    } catch (_) {
      return 'Não consegui gerar uma resposta agora.';
    }
  }

  // --- Emergency global state -----------------------------------------

  String _emergencyIntro(String reason, bool usedTemporalContext) {
    final reasonText = reason.isEmpty ? '' : ' ($reason)';
    final temporalText = usedTemporalContext
        ? ' Considerei também o contexto temporal local dos eventos recentes.'
        : '';
    return 'Percebi sinais que podem indicar uma emergência$reasonText.'
        '$temporalText Vou fazer perguntas rápidas para te orientar.';
  }

  FieldSpec? _currentEmergencyQuestion() {
    for (final field in emergencyProtocolFields) {
      if (!_emergencyData.containsKey(field.key)) return field;
    }
    return null;
  }

  bool _tryFillEmergencyField(String rawText) {
    final field = _currentEmergencyQuestion();
    if (field == null) return false;
    final yes = _matchYesNo(rawText);
    if (yes == null) return false;
    _emergencyData[field.key] = yes;
    return true;
  }

  Future<OrchestratorReply> _resolveEmergency() async {
    final field = _currentEmergencyQuestion();
    if (field != null) {
      return OrchestratorReply(field.question, quickReplies: field.quickReplies);
    }

    await storeGateway?.storeSystemEvent('emergency', {
      ..._emergencyData,
      'reason': _emergencyReason,
    });
    final guidance = _emergencyGuidanceMessage();
    _emergencyData.clear();
    _state = DiabotGlobalState.resuming;

    if (_eventStack.isEmpty && _pendingFieldKey == null) {
      _state = DiabotGlobalState.idle;
      return OrchestratorReply(guidance);
    }
    // Resume exactly where the stack was — nothing was discarded.
    return _continueAfter(guidance);
  }

  String _emergencyGuidanceMessage() {
    final canEat = _emergencyData['canEatOrDrinkSugar'] == true;
    final accompanied = _emergencyData['hasSomeoneNearby'] == true;
    final buffer = StringBuffer();
    if (canEat) {
      buffer.write(
        'Consuma um carboidrato de ação rápida agora e meça sua glicemia '
        'novamente em 15 minutos. ',
      );
    } else {
      buffer.write(
        'Como você não consegue comer ou beber algo agora, procure ajuda '
        'imediatamente. ',
      );
    }
    if (!accompanied) {
      buffer.write(
        'Como você está sozinho(a), tente contatar alguém de confiança ou '
        'os serviços de emergência agora. ',
      );
    }
    buffer.write('Isso não substitui orientação médica profissional.');
    return buffer.toString();
  }

  Future<OrchestratorReply?> _tryFillContext(String rawText) async {
    final active = _eventStack.first;
    if (_pendingFieldKey == '_contextOptIn') {
      final answer = rawText.trim().toLowerCase();
      if (answer.contains('continuar sem')) {
        active.data['_contextHandled'] = true;
        _pendingFieldKey = null;
        return _resolveStack();
      }
      if (answer.contains('adicionar') || _matchYesNo(rawText) == true) {
        _contextFieldIndex = 0;
        final field = eventContextFields[_contextFieldIndex];
        _pendingFieldKey = field.key;
        return OrchestratorReply(
          field.question,
          quickReplies: field.quickReplies,
          numericInputHint: field.numericInputHint,
        );
      }
      return null;
    }

    if (_contextFieldIndex >= eventContextFields.length) return null;
    final field = eventContextFields[_contextFieldIndex];
    final value = _parseFieldValue(field, rawText);
    if (value == null) return null;
    active.data[field.key] = value;
    _contextFieldIndex++;
    if (_contextFieldIndex < eventContextFields.length) {
      final next = eventContextFields[_contextFieldIndex];
      _pendingFieldKey = next.key;
      return OrchestratorReply(
        next.question,
        quickReplies: next.quickReplies,
        numericInputHint: next.numericInputHint,
      );
    }

    active.data['_contextHandled'] = true;
    _pendingFieldKey = null;
    return _resolveStack();
  }

  // --- Pending-field parsing (deterministic, never the LLM) ------------

  FieldSpec? _findFieldSpec(EventType type, String key) {
    final specs = eventDefinitions[type];
    if (specs == null) return null;
    for (final spec in specs) {
      if (spec.key == key) return spec;
    }
    return null;
  }

  bool _tryFillPendingField(
    EventInstance event,
    String fieldKey,
    String rawText,
  ) {
    final spec = _findFieldSpec(event.type, fieldKey);
    if (spec == null) return false;

    final value = _parseFieldValue(spec, rawText);
    if (value == null) return false;
    event.data[fieldKey] = value;
    return true;
  }

  dynamic _parseFieldValue(FieldSpec spec, String rawText) {
    switch (spec.kind) {
      case FieldKind.yesNo:
        return _matchYesNo(rawText);
      case FieldKind.number:
        return _extractNumber(rawText);
      case FieldKind.option:
        return _matchOption(rawText, spec.optionValues ?? const {});
      case FieldKind.freeText:
        final trimmed = rawText.trim();
        return trimmed.isEmpty ? null : trimmed;
    }
  }

  Future<void> _store(EventInstance event) async {
    await storeGateway?.storeEvent(event);
    await _transition(event, EventStatus.stored);
  }

  Future<void> _markStackEscalated(String reason) async {
    for (final event in _eventStack) {
      await _transition(event, EventStatus.escalated, reason: reason);
    }
  }

  Future<void> _transition(
    EventInstance event,
    EventStatus next, {
    String? reason,
  }) async {
    final previous = event.status;
    if (previous == next && event.statusReason == reason) return;
    event.transitionTo(next, reason: reason);
    await storeGateway?.recordTransition(KernelTransition(
      eventId: event.id,
      eventType: event.type,
      from: previous,
      to: next,
      globalState: _state,
      at: DateTime.now(),
      reason: reason,
    ));
  }

  double? _extractBareNumber(String text) {
    final trimmed = text.trim().replaceAll(',', '.');
    if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(trimmed)) return null;
    return double.tryParse(trimmed);
  }

  bool? _matchYesNo(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    if (t.contains('sozinho')) return false;
    if (t.startsWith('tenho alguém') || t.startsWith('tenho alguem')) {
      return true;
    }
    if (t.startsWith('não') || t.startsWith('nao') || t == 'n') return false;
    if (t.startsWith('sim') || t == 's') return true;
    if (RegExp(r'\bnão\b|\bnao\b').hasMatch(t)) return false;
    if (RegExp(r'\bsim\b').hasMatch(t)) return true;
    return null;
  }

  double? _extractNumber(String text) {
    final cleaned = text.replaceAll(',', '.');
    final match = RegExp(r'-?\d+(\.\d+)?').firstMatch(cleaned);
    if (match == null) return null;
    return double.tryParse(match.group(0)!);
  }

  String? _matchOption(String text, Map<String, String> optionsByPrefix) {
    final t = text.trim().toLowerCase();
    for (final entry in optionsByPrefix.entries) {
      if (t.contains(entry.key)) return entry.value;
    }
    return null;
  }
}

