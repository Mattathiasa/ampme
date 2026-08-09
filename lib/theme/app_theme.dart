import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ampme's brand palette and Material 3 themes.
///
/// The app ships both a **dark** theme (deep aubergine/plum canvas with dark
/// purple primary and sage accent — "nightlife audio") and a **light** theme
/// that mirrors the same brand on a soft lavender-white canvas. Centralised
/// here so every screen shares the same colours, shapes, and component
/// styling, and `MaterialApp` picks one via `ThemeMode.system`.
class AppTheme {
  const AppTheme._();

  // ---- Brand colours ----

  /// Dark purple — the primary brand colour (buttons, active states).
  static const Color purple = Color(0xFF7C5CE0);
  static const Color purpleBright = Color(0xFF9B7BFF);

  /// Sage green — the accent (sync/live indicators, secondary actions).
  static const Color sage = Color(0xFF9DB38A);
  static const Color sageBright = Color(0xFFB6CCA1);

  // ---- Dark canvas (deep plum) ----
  static const Color _bg = Color(0xFF140F1F);
  static const Color _surface = Color(0xFF1C1630);
  static const Color _surfaceContainer = Color(0xFF241C3B);
  static const Color _surfaceContainerHigh = Color(0xFF2E2447);
  static const Color _outline = Color(0xFF473A63);

  // ---- Light canvas (soft lavender-white) ----
  static const Color _lightBg = Color(0xFFF7F5FB);
  static const Color _lightSurface = Color(0xFFF0ECF8);
  static const Color _lightSurfaceContainerHigh = Color(0xFFEAE5F3);
  static const Color _lightOutline = Color(0xFFCBC4E2);
  static const Color _sageDark = Color(0xFF5B7249);

  static ThemeData light() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: purple,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFE7DEFF),
      onPrimaryContainer: Color(0xFF2A1A55),
      secondary: _sageDark,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFDCEBCF),
      onSecondaryContainer: Color(0xFF1A2E10),
      tertiary: Color(0xFF44663C),
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFC5EAB8),
      onTertiaryContainer: Color(0xFF0C1F08),
      error: Color(0xFFBA1A1A),
      onError: Colors.white,
      errorContainer: Color(0xFFFFDAD6),
      onErrorContainer: Color(0xFF410002),
      surface: _lightSurface,
      onSurface: Color(0xFF1C1630),
      onSurfaceVariant: Color(0xFF5E5678),
      surfaceContainerLowest: _lightBg,
      surfaceContainerLow: _lightSurface,
      surfaceContainer: _lightSurface,
      surfaceContainerHigh: _lightSurfaceContainerHigh,
      surfaceContainerHighest: _lightSurfaceContainerHigh,
      outline: Color(0xFF7A7398),
      outlineVariant: _lightOutline,
      inverseSurface: Color(0xFF322B49),
      onInverseSurface: Color(0xFFF0EAFE),
      inversePrimary: Color(0xFFCDBBFF),
      shadow: Colors.black,
      scrim: Colors.black,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      scaffoldBackgroundColor: _lightBg,
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Color(0xFF1C1630),
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: Color(0xFF1C1630),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: _lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _lightOutline.withValues(alpha: 0.8)),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          backgroundColor: purple,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          foregroundColor: _sageDark,
          side: BorderSide(color: _sageDark.withValues(alpha: 0.5), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: _sageDark),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: scheme.onSurface),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _lightSurfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _lightOutline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: purpleBright, width: 2),
        ),
        labelStyle: const TextStyle(color: Color(0xFF5E5678)),
        floatingLabelStyle: const TextStyle(color: purple),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: purpleBright,
        inactiveTrackColor: _lightOutline,
        thumbColor: purpleBright,
        overlayColor: purpleBright.withValues(alpha: 0.16),
      ),
      dividerTheme: DividerThemeData(color: _lightOutline.withValues(alpha: 0.7), thickness: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: _surfaceContainerHigh,
        contentTextStyle: const TextStyle(color: Color(0xFFEDE8F7)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: const ListTileThemeData(iconColor: _sageDark),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: purpleBright),
    );
  }

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: purple,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFF3A2A66),
      onPrimaryContainer: Color(0xFFE7DEFF),
      secondary: sage,
      onSecondary: Color(0xFF14210C),
      secondaryContainer: Color(0xFF33422A),
      onSecondaryContainer: Color(0xFFDCEBCF),
      tertiary: sageBright,
      onTertiary: Color(0xFF14210C),
      tertiaryContainer: Color(0xFF33422A),
      onTertiaryContainer: Color(0xFFDCEBCF),
      error: Color(0xFFFF6B7A),
      onError: Color(0xFF3B0710),
      errorContainer: Color(0xFF5A1622),
      onErrorContainer: Color(0xFFFFDADE),
      surface: _surface,
      onSurface: Color(0xFFEDE8F7),
      onSurfaceVariant: Color(0xFFB6AECB),
      surfaceContainerLowest: _bg,
      surfaceContainerLow: _surface,
      surfaceContainer: _surfaceContainer,
      surfaceContainerHigh: _surfaceContainerHigh,
      surfaceContainerHighest: _surfaceContainerHigh,
      outline: _outline,
      outlineVariant: Color(0xFF352B4D),
      inverseSurface: Color(0xFFEDE8F7),
      onInverseSurface: Color(0xFF241C3B),
      inversePrimary: Color(0xFF3A2A66),
      shadow: Colors.black,
      scrim: Colors.black,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      scaffoldBackgroundColor: _bg,
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Color(0xFFEDE8F7),
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: Color(0xFFEDE8F7),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: _surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: _outline.withValues(alpha: 0.5)),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          backgroundColor: purple,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          foregroundColor: sageBright,
          side: BorderSide(color: sage.withValues(alpha: 0.6), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: sageBright),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: scheme.onSurface),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _outline.withValues(alpha: 0.6)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: purpleBright, width: 2),
        ),
        labelStyle: const TextStyle(color: Color(0xFFB6AECB)),
        floatingLabelStyle: const TextStyle(color: purpleBright),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: purpleBright,
        inactiveTrackColor: _outline,
        thumbColor: Colors.white,
        overlayColor: purpleBright.withValues(alpha: 0.16),
      ),
      dividerTheme: DividerThemeData(color: _outline.withValues(alpha: 0.5), thickness: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: _surfaceContainerHigh,
        contentTextStyle: const TextStyle(color: Color(0xFFEDE8F7)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: const ListTileThemeData(iconColor: sageBright),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: purpleBright),
    );
  }

  /// A soft brand gradient used behind hero/header areas — plum fading down
  /// into the canvas with a whisper of sage at the edge (dark), or a pale
  /// lavender-to-mint wash (light).
  static LinearGradient heroGradient(ColorScheme scheme) {
    if (scheme.brightness == Brightness.light) {
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFE3DBF7), _lightBg, Color(0xFFE8EFE3)],
        stops: [0.0, 0.55, 1.0],
      );
    }
    return const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF2A1E4A), _bg, Color(0xFF17221A)],
      stops: [0.0, 0.55, 1.0],
    );
  }
}
