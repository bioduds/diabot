import 'package:flutter/material.dart';

/// Dark, violet-accented visual language shared across the whole app.
class DiabAIPalette {
  static const background = Color(0xFF010714);
  static const surface = Color(0xFF1E1E2A);
  static const surfaceBorder = Color(0x0FFFFFFF);
  static const textPrimary = Color(0xFFF0F0F5);
  static const textSecondary = Color(0xFFE0E0F0);
  static const textMuted = Color(0xFF55556A);
  static const iconMuted = Color(0xFF7A7A9A);
  static const accent = Color(0xFF6C63FF);
  static const accentAlt = Color(0xFFA855F7);
  static const online = Color(0xFF22C55E);
  static const offline = Color(0xFFEF4444);
  static const chipBorder = Color(0x4D6C63FF);
  static const chipText = Color(0xFFA0A0C8);

  static const accentGradient = LinearGradient(
    colors: [accent, accentAlt],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const userBubbleGradient = LinearGradient(
    colors: [accent, Color(0xFF7C4DFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

/// Shared dark theme applied to the chat and profile screens' subtrees.
ThemeData get diabAITheme {
  const scheme = ColorScheme.dark(
    primary: DiabAIPalette.accent,
    onPrimary: Colors.white,
    secondary: DiabAIPalette.accentAlt,
    onSecondary: Colors.white,
    surface: DiabAIPalette.surface,
    onSurface: DiabAIPalette.textSecondary,
    surfaceContainerHighest: DiabAIPalette.surface,
    error: DiabAIPalette.offline,
    onError: Colors.white,
    outline: DiabAIPalette.surfaceBorder,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: DiabAIPalette.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: DiabAIPalette.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: DiabAIPalette.textPrimary,
      actionsIconTheme: IconThemeData(color: DiabAIPalette.iconMuted),
      elevation: 0,
    ),
    iconTheme: const IconThemeData(color: DiabAIPalette.iconMuted),
    dividerColor: DiabAIPalette.surfaceBorder,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DiabAIPalette.surface,
      hintStyle: const TextStyle(color: DiabAIPalette.iconMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: DiabAIPalette.surfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: DiabAIPalette.surfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: DiabAIPalette.accent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        side: const BorderSide(color: DiabAIPalette.chipBorder),
        foregroundColor: DiabAIPalette.chipText,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: DiabAIPalette.accent,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: DiabAIPalette.chipText),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: DiabAIPalette.iconMuted),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: DiabAIPalette.surface,
      textStyle: TextStyle(color: DiabAIPalette.textSecondary),
    ),
    textTheme: Typography.whiteMountainView.apply(
      bodyColor: DiabAIPalette.textSecondary,
      displayColor: DiabAIPalette.textPrimary,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: DiabAIPalette.accent,
    ),
  );
}
