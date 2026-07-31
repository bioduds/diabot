import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Loads UI copy from localization resources. Domain and Kernel code only
/// carries stable keys; it never needs to inspect human language.
class UiText {
  UiText._(this._messages);

  final Map<String, String> _messages;

  static UiText? _current;

  static UiText get current {
    final current = _current;
    if (current == null) throw StateError('UiText has not been loaded.');
    return current;
  }

  static Future<void> load(String languageCode) async {
    final asset = 'assets/i18n/$languageCode.json';
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(await rootBundle.loadString(asset))
          as Map<String, dynamic>;
    } catch (_) {
      decoded = jsonDecode(await rootBundle.loadString('assets/i18n/pt-BR.json'))
          as Map<String, dynamic>;
    }
    _current = UiText._(decoded.map(
      (key, value) => MapEntry(key, value as String),
    ));
  }

  String get(String key) => _messages[key] ?? key;
}
