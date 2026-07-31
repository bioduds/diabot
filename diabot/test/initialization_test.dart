import 'package:diabai/initialization.dart';
import 'package:diabai/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final last = await module.respond('Fiasp');

    expect(first.text, contains('peso atual'));
    expect(module.isComplete, isTrue);
    expect(last.text, contains('Perfil inicial salvo'));
    expect((await UserProfile.load()).nome, 'Ana');
    expect((await UserProfile.load()).idioma, 'pt');
  });
}
