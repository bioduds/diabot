import 'events.dart';
import 'user_profile.dart';

class InitializationReply {
  const InitializationReply({
    required this.text,
    this.quickReplies,
  });

  final String text;
  final List<String>? quickReplies;
}

/// Collects and saves the local profile for the onboarding FSM entry point.
/// It does not create events, evaluate health data, or choose global states.
class InitializationModule {
  UserProfile? _profile;
  int _step = 0;

  bool get isComplete => _profile != null && _step >= onboardingQuestions.length;

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
    return _nextReply();
  }

  Future<InitializationReply> respond(String rawText) async {
    final profile = _profile;
    if (profile == null || isComplete) {
      throw StateError('Initialization has not started or is already complete.');
    }

    final answer = rawText.trim();
    if (answer.isEmpty) return _nextReply();
    onboardingQuestions[_step].setter(profile, answer);
    _step += 1;
    _skipKnownFields();
    return _nextReply();
  }

  void _skipKnownFields() {
    final profile = _profile!;
    while (_step < onboardingQuestions.length &&
        onboardingQuestions[_step].getter(profile).isNotEmpty) {
      _step += 1;
    }
  }

  Future<InitializationReply> _nextReply() async {
    if (!isComplete) {
      return InitializationReply(
        text: onboardingQuestions[_step].question,
      );
    }

    await _profile!.save();
    return const InitializationReply(
      text: 'Perfil inicial salvo. O que você quer registrar agora?',
      quickReplies: SuggestionEngine.idleActions,
    );
  }
}
