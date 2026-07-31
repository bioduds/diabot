import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Locally-stored user profile captured during first-login onboarding.
///
/// This data never leaves the device: it is persisted only via
/// [SharedPreferences] and is used to personalize the on-device Gemma
/// system prompt used by the local language-model runtime.
class UserProfile {
  static const _prefsKey = 'diabai_user_profile';

  String idioma;
  String nome;
  String email;
  String fotoUrl;
  String peso;
  String tipoDiabetes;
  String tempoDiagnostico;
  String insulinas;

  UserProfile({
    this.idioma = '',
    this.nome = '',
    this.email = '',
    this.fotoUrl = '',
    this.peso = '',
    this.tipoDiabetes = '',
    this.tempoDiagnostico = '',
    this.insulinas = '',
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      idioma: json['idioma'] as String? ?? '',
      nome: json['nome'] as String? ?? '',
      email: json['email'] as String? ?? '',
      fotoUrl: json['fotoUrl'] as String? ?? '',
      peso: json['peso'] as String? ?? '',
      tipoDiabetes: json['tipoDiabetes'] as String? ?? '',
      tempoDiagnostico: json['tempoDiagnostico'] as String? ?? '',
      insulinas: json['insulinas'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'idioma': idioma,
        'nome': nome,
        'email': email,
        'fotoUrl': fotoUrl,
        'peso': peso,
        'tipoDiabetes': tipoDiabetes,
        'tempoDiagnostico': tempoDiagnostico,
        'insulinas': insulinas,
      };

  /// Returns true when a profile has been fully captured and saved.
  static Future<bool> isComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_prefsKey);
  }

  /// Loads the saved profile, or an empty one if none has been saved yet.
  static Future<UserProfile> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return UserProfile();
    try {
      return UserProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return UserProfile();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  /// A short line summarizing the profile, meant to be injected into the
  /// Gemma system prompt so responses can be personalized.
  String toPromptSummary() {
    final parts = <String>[];
    if (nome.isNotEmpty) parts.add('nome=$nome');
    if (peso.isNotEmpty) parts.add('peso=$peso');
    if (tipoDiabetes.isNotEmpty) parts.add('tipo de diabetes=$tipoDiabetes');
    if (tempoDiagnostico.isNotEmpty) {
      parts.add('tempo de diagnóstico=$tempoDiagnostico');
    }
    if (insulinas.isNotEmpty) parts.add('insulinas utilizadas=$insulinas');
    if (parts.isEmpty) return '';
    return 'Dados do usuário (use para personalizar, nunca para prescrever): '
        '${parts.join('; ')}.';
  }
}

/// Best-effort mapping from a free-text language answer (Portuguese word,
/// English word, or an ISO 639-1 code already) to the ISO 639-1 code
/// expected by the Whisper STT model's `language` config. Falls back to
/// Portuguese if nothing recognizable is typed, since that's this app's
/// primary audience.
String normalizeLanguageAnswer(String rawAnswer) {
  final normalized = rawAnswer.trim().toLowerCase();
  const knownLanguages = {
    'português': 'pt',
    'portugues': 'pt',
    'pt': 'pt',
    'pt-br': 'pt',
    'inglês': 'en',
    'ingles': 'en',
    'english': 'en',
    'en': 'en',
    'espanhol': 'es',
    'español': 'es',
    'spanish': 'es',
    'es': 'es',
    'russo': 'ru',
    'russian': 'ru',
    'ru': 'ru',
    'francês': 'fr',
    'frances': 'fr',
    'french': 'fr',
    'fr': 'fr',
    'alemão': 'de',
    'alemao': 'de',
    'german': 'de',
    'de': 'de',
    'italiano': 'it',
    'italian': 'it',
    'it': 'it',
  };
  if (knownLanguages.containsKey(normalized)) {
    return knownLanguages[normalized]!;
  }
  if (normalized.length == 2) return normalized;
  return 'pt';
}

/// One scripted onboarding question, mapping directly to a [UserProfile] field.
class OnboardingQuestion {
  final String field;
  final String question;
  final String Function(UserProfile) getter;
  final void Function(UserProfile, String) setter;

  const OnboardingQuestion({
    required this.field,
    required this.question,
    required this.getter,
    required this.setter,
  });
}

/// Fixed, ordered profile fields collected by the FSM initialization module
/// (confirmed field set: idioma, nome, peso, tipo de diabetes, tempo de
/// diagnóstico, insulinas utilizadas). `idioma` and `nome` are normally
/// auto-filled (device locale / Google account) and skipped by
/// [InitializationModule].
final List<OnboardingQuestion> onboardingQuestions = [
  OnboardingQuestion(
    field: 'idioma',
    question:
        'Qual idioma voc\u00ea fala (ex: portugu\u00eas, ingl\u00eas, espanhol)? '
        'Isso ajuda o reconhecimento de voz a te entender melhor.',
    getter: (p) => p.idioma,
    setter: (p, v) => p.idioma = normalizeLanguageAnswer(v),
  ),
  OnboardingQuestion(
    field: 'nome',
    question: 'Olá! Antes de começarmos, como você gostaria de ser chamado(a)?',
    getter: (p) => p.nome,
    setter: (p, v) => p.nome = v,
  ),
  OnboardingQuestion(
    field: 'peso',
    question: 'Qual é o seu peso atual (ex: 70 kg)?',
    getter: (p) => p.peso,
    setter: (p, v) => p.peso = v,
  ),
  OnboardingQuestion(
    field: 'tipoDiabetes',
    question:
        'Qual o tipo de diabetes você tem (Tipo 1, Tipo 2, Gestacional, outro)?',
    getter: (p) => p.tipoDiabetes,
    setter: (p, v) => p.tipoDiabetes = v,
  ),
  OnboardingQuestion(
    field: 'tempoDiagnostico',
    question:
        'Há quanto tempo você tem diabetes (ex: 3 anos, recém diagnosticado)?',
    getter: (p) => p.tempoDiagnostico,
    setter: (p, v) => p.tempoDiagnostico = v,
  ),
  OnboardingQuestion(
    field: 'insulinas',
    question:
        'Quais insulinas você utiliza atualmente (basal e/ou bolus, se souber os nomes)?',
    getter: (p) => p.insulinas,
    setter: (p, v) => p.insulinas = v,
  ),
];
