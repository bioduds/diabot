import 'events.dart';
import 'librelinkup.dart';
import 'user_profile.dart';

class InitializationReply {
  const InitializationReply({
    required this.text,
    this.quickReplies,
    this.obscureNextAnswer = false,
    this.kind = FieldKind.freeText,
    this.numericInputHint,
    this.unitOptions = const [],
  });

  final String text;
  final List<String>? quickReplies;

  /// True only for the LibreLinkUp password question: the UI must not
  /// echo the typed answer in the chat log or input field.
  final bool obscureNextAnswer;

  /// Determines the keyboard/control the guided input panel shows for the
  /// answer to this question (e.g. numeric keyboard for weight).
  final FieldKind kind;
  final String? numericInputHint;

  /// Pre-selectable unit labels (e.g. ['kg', 'lb']) shown next to a
  /// [FieldKind.number] question. Empty when the question has no units.
  final List<String> unitOptions;
}

/// The CGM sub-flow's own tiny step machine, asked right after the fixed
/// profile questions. See docs/fsm/cgm.mmd: it only ever writes
/// `cgmUsaServico`/`cgmProvider`/`cgmLibreLinkUpConectado` profile facts —
/// no new EventType, EventStatus, or DiabAIGlobalState.
enum _CgmStep { usage, provider, email, password, done }

/// Collects and saves the local profile for the onboarding FSM entry point.
/// It does not create events, evaluate health data, or choose global states.
class InitializationModule {
  InitializationModule({
    LibreLinkUpClient? libreLinkUpClient,
    LibreLinkUpCredentialStore? libreLinkUpCredentialStore,
  })  : _libreLinkUpClient = libreLinkUpClient ?? LibreLinkUpClient(),
        _libreLinkUpCredentialStore =
            libreLinkUpCredentialStore ?? LibreLinkUpCredentialStore();

  static const _introMessage = 'Olá! Eu sou o Nuno, seu assistente de '
      'diabetes. Vou te ajudar no acompanhamento da sua glicemia, '
      'refeições, insulina, atividade física e situações de emergência. '
      'Antes de começarmos, preciso confirmar alguns dados rapidinho.';

  static const _cgmUsageQuestion = 'Você utiliza algum serviço de CGM — '
      'Monitor Contínuo de Glicose (um sensor que mede sua glicemia '
      'automaticamente ao longo do dia, sem picadas repetidas no dedo)?';
  static const _cgmProviderQuestion = 'Qual sensor de CGM você usa?';
  static const _cgmEmailQuestion =
      'Qual é o e-mail da sua conta LibreLinkUp?';
  static const _cgmPasswordQuestion =
      'Qual é a senha da sua conta LibreLinkUp? Ela é usada só para '
      'conectar ao servidor da Abbott/LibreLinkUp e fica guardada de forma '
      'criptografada apenas neste aparelho.';
  static const _cgmProviderOptions = [
    'FreeStyle Libre 2',
    'FreeStyle Libre 2 Plus',
    'FreeStyle Libre 3',
    'Dexcom',
    'Outro',
  ];

  final LibreLinkUpClient _libreLinkUpClient;
  final LibreLinkUpCredentialStore _libreLinkUpCredentialStore;

  UserProfile? _profile;
  int _step = 0;
  _CgmStep _cgmStep = _CgmStep.usage;
  String? _cgmEmail;

  bool get isComplete =>
      _profile != null &&
      _step >= onboardingQuestions.length &&
      _cgmStep == _CgmStep.done;

  Future<InitializationReply> begin({
    required UserProfile profile,
    required String deviceLanguage,
    String? accountDisplayName,
  }) async {
    _profile = profile;
    _step = 0;
    if (profile.idioma.isEmpty && deviceLanguage.isNotEmpty) {
      profile.idioma = deviceLanguage;
    }
    final displayName = accountDisplayName?.trim();
    if (profile.nome.isEmpty && displayName != null && displayName.isNotEmpty) {
      profile.nome = displayName;
    }
    _skipKnownFields();
    _resumeCgmStep();
    final reply = await _nextReply();
    if (isComplete) return reply;
    return InitializationReply(
      text: '$_introMessage\n\n${reply.text}',
      quickReplies: reply.quickReplies,
      obscureNextAnswer: reply.obscureNextAnswer,
      kind: reply.kind,
      numericInputHint: reply.numericInputHint,
      unitOptions: reply.unitOptions,
    );
  }

  Future<InitializationReply> respond(String rawText) async {
    final profile = _profile;
    if (profile == null || isComplete) {
      throw StateError('Initialization has not started or is already complete.');
    }

    final answer = rawText.trim();
    if (answer.isEmpty) return _nextReply();

    if (_step < onboardingQuestions.length) {
      onboardingQuestions[_step].setter(profile, answer);
      _step += 1;
      _skipKnownFields();
      return _nextReply();
    }

    return _handleCgmAnswer(profile, answer);
  }

  void _skipKnownFields() {
    final profile = _profile!;
    while (_step < onboardingQuestions.length &&
        onboardingQuestions[_step].getter(profile).isNotEmpty) {
      _step += 1;
    }
  }

  /// Resumes the CGM sub-flow at the right step when a partial profile
  /// already answered some of it (e.g. onboarding was interrupted).
  void _resumeCgmStep() {
    final profile = _profile!;
    if (profile.cgmUsaServico.isEmpty) {
      _cgmStep = _CgmStep.usage;
    } else if (profile.cgmUsaServico != 'sim') {
      _cgmStep = _CgmStep.done;
    } else if (profile.cgmProvider.isEmpty) {
      _cgmStep = _CgmStep.provider;
    } else if (!_isLibreProvider(profile.cgmProvider)) {
      _cgmStep = _CgmStep.done;
    } else if (profile.cgmLibreLinkUpConectado.isNotEmpty) {
      _cgmStep = _CgmStep.done;
    } else {
      _cgmStep = _CgmStep.email;
    }
  }

  bool _isYes(String answer) {
    final normalized = answer.trim().toLowerCase();
    return normalized == 's' || normalized.startsWith('sim');
  }

  bool _isLibreProvider(String provider) =>
      provider.trim().toLowerCase().contains('libre');

  Future<InitializationReply> _handleCgmAnswer(
      UserProfile profile, String answer) async {
    switch (_cgmStep) {
      case _CgmStep.usage:
        final usesService = _isYes(answer);
        profile.cgmUsaServico = usesService ? 'sim' : 'não';
        _cgmStep = usesService ? _CgmStep.provider : _CgmStep.done;
        return _nextReply();
      case _CgmStep.provider:
        profile.cgmProvider = answer;
        if (_isLibreProvider(answer)) {
          _cgmStep = _CgmStep.email;
        } else {
          profile.cgmLibreLinkUpConectado = 'não';
          _cgmStep = _CgmStep.done;
        }
        return _nextReply();
      case _CgmStep.email:
        _cgmEmail = answer;
        _cgmStep = _CgmStep.password;
        return _nextReply();
      case _CgmStep.password:
        return _attemptLibreLinkUpConnection(profile, password: answer);
      case _CgmStep.done:
        return _nextReply();
    }
  }

  Future<InitializationReply> _attemptLibreLinkUpConnection(
    UserProfile profile, {
    required String password,
  }) async {
    final email = _cgmEmail ?? '';
    String notice;
    try {
      final result = await _libreLinkUpClient.connect(
        email: email,
        password: password,
      );
      await _libreLinkUpCredentialStore.save(
        email: email,
        password: password,
        regionCode: result.region.code,
        patientId: result.patient.patientId,
        patientName: result.patient.fullName,
      );
      profile.cgmLibreLinkUpConectado = 'sim';
      final name = result.patient.fullName;
      notice = 'Conectado ao LibreLinkUp com sucesso!'
          '${name.isNotEmpty ? ' Encontrei os dados de $name.' : ''} '
          'Vou sincronizar sua glicemia automaticamente a partir de agora.';
    } on LibreLinkUpException catch (e) {
      profile.cgmLibreLinkUpConectado = 'não';
      notice = 'Não consegui conectar ao LibreLinkUp: ${e.message} '
          'Você pode tentar novamente depois pela tela de Perfil. Por '
          'enquanto vamos seguir só com o registro manual de glicemia.';
    }
    _cgmStep = _CgmStep.done;
    final reply = await _nextReply();
    return InitializationReply(
      text: '$notice\n\n${reply.text}',
      quickReplies: reply.quickReplies,
    );
  }

  Future<InitializationReply> _nextReply() async {
    if (_step < onboardingQuestions.length) {
      final question = onboardingQuestions[_step];
      return InitializationReply(
        text: question.question,
        kind: question.kind,
        numericInputHint: question.numericInputHint,
        unitOptions: question.unitOptions,
      );
    }

    switch (_cgmStep) {
      case _CgmStep.usage:
        return const InitializationReply(
          text: _cgmUsageQuestion,
          quickReplies: ['Sim', 'Não'],
        );
      case _CgmStep.provider:
        return const InitializationReply(
          text: _cgmProviderQuestion,
          quickReplies: _cgmProviderOptions,
        );
      case _CgmStep.email:
        return const InitializationReply(text: _cgmEmailQuestion);
      case _CgmStep.password:
        return const InitializationReply(
          text: _cgmPasswordQuestion,
          obscureNextAnswer: true,
        );
      case _CgmStep.done:
        break;
    }

    await _profile!.save();
    return const InitializationReply(
      text: 'Perfil inicial salvo. O que você quer registrar agora?',
      quickReplies: SuggestionEngine.idleActions,
    );
  }
}
