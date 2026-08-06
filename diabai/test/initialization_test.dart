import 'package:diabai/events.dart';
import 'package:diabai/initialization.dart';
import 'package:diabai/librelinkup.dart';
import 'package:diabai/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLibreLinkUpClient extends LibreLinkUpClient {
  _FakeLibreLinkUpClient.success()
      : _result = LibreLinkUpConnectResult(
          region: LibreLinkUpRegion.fromCode('US'),
          token: 'token-123',
          accountIdHash: 'hash-123',
          patient: const LibreLinkUpPatient(
            patientId: 'patient-1',
            firstName: 'Ana',
            lastName: '',
          ),
        ),
        _failure = null;

  _FakeLibreLinkUpClient.failure(String message)
      : _result = null,
        _failure = LibreLinkUpException(message);

  final LibreLinkUpConnectResult? _result;
  final LibreLinkUpException? _failure;

  @override
  Future<LibreLinkUpConnectResult> connect({
    required String email,
    required String password,
    String regionCode = 'LA',
  }) async {
    if (_failure != null) throw _failure;
    return _result!;
  }
}

/// Fails the first connection attempt (wrong password), then succeeds on
/// any subsequent attempt — used to test the onboarding retry step.
class _FakeRetryingLibreLinkUpClient extends LibreLinkUpClient {
  bool _hasFailedOnce = false;

  @override
  Future<LibreLinkUpConnectResult> connect({
    required String email,
    required String password,
    String regionCode = 'LA',
  }) async {
    if (!_hasFailedOnce) {
      _hasFailedOnce = true;
      throw LibreLinkUpException('E-mail ou senha inválidos.');
    }
    return LibreLinkUpConnectResult(
      region: LibreLinkUpRegion.fromCode('US'),
      token: 'token-123',
      accountIdHash: 'hash-123',
      patient: const LibreLinkUpPatient(
        patientId: 'patient-1',
        firstName: 'Ana',
        lastName: '',
      ),
    );
  }
}

class _FakeCredentialStore extends LibreLinkUpCredentialStore {
  final saved = <String, String>{};

  @override
  Future<void> save({
    required String email,
    required String password,
    required String regionCode,
    required String patientId,
    required String patientName,
  }) async {
    saved
      ..['email'] = email
      ..['password'] = password
      ..['regionCode'] = regionCode
      ..['patientId'] = patientId
      ..['patientName'] = patientName;
  }

  @override
  Future<bool> get isConnected async => saved.containsKey('email');

  @override
  Future<
      ({
        String email,
        String password,
        String regionCode,
        String patientId,
        String patientName,
      })?> load() async {
    if (!saved.containsKey('email')) return null;
    return (
      email: saved['email']!,
      password: saved['password']!,
      regionCode: saved['regionCode']!,
      patientId: saved['patientId']!,
      patientName: saved['patientName']!,
    );
  }

  @override
  Future<DateTime?> get lastSyncedAt async => null;

  @override
  Future<void> setLastSyncedAt(DateTime at) async {}

  @override
  Future<void> clear() async => saved.clear();
}

Future<InitializationReply> _completeFixedQuestions(
    InitializationModule module) async {
  final first = await module.begin(
    profile: UserProfile(),
    deviceLanguage: 'pt',
    accountDisplayName: 'Ana',
  );
  await module.respond('70 kg');
  await module.respond('Tipo 1');
  await module.respond('3 anos');
  final afterFixedQuestions = await module.respond('Fiasp');
  expect(first.text, contains('peso atual'));
  return afterFixedQuestions;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('collects and saves the initial profile', () async {
    final module = InitializationModule();
    final profile = UserProfile();

    final first = await module.begin(
      profile: profile,
      deviceLanguage: 'pt',
      accountDisplayName: 'Ana',
    );
    await module.respond('70 kg');
    await module.respond('Tipo 1');
    await module.respond('3 anos');
    final afterFixedQuestions = await module.respond('Fiasp');
    final last = await module.respond('Não');

    expect(first.text, contains('peso atual'));
    expect(afterFixedQuestions.text, contains('CGM'));
    expect(module.isComplete, isTrue);
    expect(last.text, contains('Perfil inicial salvo'));
    expect((await UserProfile.load()).nome, 'Ana');
    expect((await UserProfile.load()).idioma, 'pt');
  });

  test('weight question asks for a number with pre-selectable units',
      () async {
    final module = InitializationModule();
    final first = await module.begin(
      profile: UserProfile(),
      deviceLanguage: 'pt',
      accountDisplayName: 'Ana',
    );

    expect(first.kind, FieldKind.number);
    expect(first.unitOptions, ['kg', 'lb']);
  });

  test('a weight typed in pounds is normalized and stored in kg', () async {
    final module = InitializationModule();
    await module.begin(
      profile: UserProfile(),
      deviceLanguage: 'pt',
      accountDisplayName: 'Ana',
    );
    await module.respond('154 lb');
    await module.respond('Tipo 1');
    await module.respond('3 anos');
    await module.respond('Fiasp');
    await module.respond('Não');

    expect((await UserProfile.load()).peso, '69.9 kg');
  });

  test('CGM sub-flow skips provider/credentials when user says no', () async {
    final module = InitializationModule();
    await _completeFixedQuestions(module);
    final done = await module.respond('Não');

    expect(module.isComplete, isTrue);
    expect(done.text, contains('Perfil inicial salvo'));
    expect((await UserProfile.load()).cgmUsaServico, 'não');
    expect((await UserProfile.load()).cgmLibreLinkUpConectado, isEmpty);
  });

  test('CGM sub-flow skips credentials for a non-Libre provider', () async {
    final module = InitializationModule();
    await _completeFixedQuestions(module);
    await module.respond('Sim');
    final done = await module.respond('Dexcom');

    expect(module.isComplete, isTrue);
    expect(done.text, contains('Perfil inicial salvo'));
    expect((await UserProfile.load()).cgmProvider, 'Dexcom');
    expect((await UserProfile.load()).cgmLibreLinkUpConectado, 'não');
  });

  test('CGM sub-flow asks for LibreLinkUp credentials and masks the password '
      'question', () async {
    final credentialStore = _FakeCredentialStore();
    final module = InitializationModule(
      libreLinkUpClient: _FakeLibreLinkUpClient.success(),
      libreLinkUpCredentialStore: credentialStore,
    );
    await _completeFixedQuestions(module);
    await module.respond('Sim');
    final providerReply = await module.respond('FreeStyle Libre 2 Plus');
    expect(providerReply.text, contains('e-mail'));
    final emailReply = await module.respond('ana@example.com');
    expect(emailReply.obscureNextAnswer, isTrue);
    final done = await module.respond('super-secret');

    expect(module.isComplete, isTrue);
    expect(done.text, contains('Conectado ao LibreLinkUp com sucesso'));
    expect((await UserProfile.load()).cgmLibreLinkUpConectado, 'sim');
    expect(credentialStore.saved['email'], 'ana@example.com');
    expect(credentialStore.saved['password'], 'super-secret');
    expect(credentialStore.saved['patientId'], 'patient-1');
  });

  test('CGM sub-flow reports a failed LibreLinkUp connection and offers a '
      'retry before completing onboarding', () async {
    final module = InitializationModule(
      libreLinkUpClient:
          _FakeLibreLinkUpClient.failure('E-mail ou senha inválidos.'),
      libreLinkUpCredentialStore: _FakeCredentialStore(),
    );
    await _completeFixedQuestions(module);
    await module.respond('Sim');
    await module.respond('FreeStyle Libre 2');
    await module.respond('ana@example.com');
    final afterFailure = await module.respond('wrong-password');

    expect(module.isComplete, isFalse);
    expect(afterFailure.text, contains('Não consegui conectar'));
    expect(afterFailure.quickReplies,
        contains('Tentar novamente'));
    expect((await UserProfile.load()).cgmLibreLinkUpConectado, isEmpty);

    final done = await module.respond('Continuar sem conectar');
    expect(module.isComplete, isTrue);
    expect(done.text, contains('Perfil inicial salvo'));
    expect((await UserProfile.load()).cgmLibreLinkUpConectado, 'não');
  });

  test('CGM sub-flow lets the user retry credentials and connect '
      'successfully the second time', () async {
    final credentialStore = _FakeCredentialStore();
    final module = InitializationModule(
      libreLinkUpClient: _FakeRetryingLibreLinkUpClient(),
      libreLinkUpCredentialStore: credentialStore,
    );
    await _completeFixedQuestions(module);
    await module.respond('Sim');
    await module.respond('FreeStyle Libre 2');
    await module.respond('ana@example.com');
    final afterFailure = await module.respond('wrong-password');
    expect(afterFailure.quickReplies, contains('Tentar novamente'));

    final emailReply = await module.respond('Tentar novamente');
    expect(emailReply.text, contains('e-mail'));
    final passwordReply = await module.respond('ana@example.com');
    expect(passwordReply.obscureNextAnswer, isTrue);
    final done = await module.respond('correct-password');

    expect(module.isComplete, isTrue);
    expect(done.text, contains('Conectado ao LibreLinkUp com sucesso'));
    expect((await UserProfile.load()).cgmLibreLinkUpConectado, 'sim');
    expect(credentialStore.saved['password'], 'correct-password');
  });
}
