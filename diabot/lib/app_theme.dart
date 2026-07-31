import 'package:flutter/material.dart';

/// Dark, violet-accented visual language shared across the whole app.
class DiabotPalette {
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
ThemeData get diabotTheme {
  const scheme = ColorScheme.dark(
    primary: DiabotPalette.accent,
    onPrimary: Colors.white,
    secondary: DiabotPalette.accentAlt,
    onSecondary: Colors.white,
    surface: DiabotPalette.surface,
    onSurface: DiabotPalette.textSecondary,
    surfaceContainerHighest: DiabotPalette.surface,
    error: DiabotPalette.offline,
    onError: Colors.white,
    outline: DiabotPalette.surfaceBorder,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: DiabotPalette.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: DiabotPalette.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: DiabotPalette.textPrimary,
      actionsIconTheme: IconThemeData(color: DiabotPalette.iconMuted),
      elevation: 0,
    ),
    iconTheme: const IconThemeData(color: DiabotPalette.iconMuted),
    dividerColor: DiabotPalette.surfaceBorder,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DiabotPalette.surface,
      hintStyle: const TextStyle(color: DiabotPalette.iconMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: DiabotPalette.surfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: DiabotPalette.surfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: DiabotPalette.accent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        side: const BorderSide(color: DiabotPalette.chipBorder),
        foregroundColor: DiabotPalette.chipText,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: DiabotPalette.accent,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: DiabotPalette.chipText),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: DiabotPalette.iconMuted),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: DiabotPalette.surface,
      textStyle: TextStyle(color: DiabotPalette.textSecondary),
    ),
    textTheme: Typography.whiteMountainView.apply(
      bodyColor: DiabotPalette.textSecondary,
      displayColor: DiabotPalette.textPrimary,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: DiabotPalette.accent,
    ),
  );
}
