import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ampme's brand palette and Material 3 theme.
///
/// The app is dark-first: a deep aubergine/plum canvas with **dark purple**
/// as the primary brand colour and **sage green** as the accent, so the two
/// read as "nightlife audio" without fighting each other. Centralised here so
/// every screen shares the same colours, shapes, and component styling.
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

  /// The app deliberately ships a single dark theme; [light] returns the same
  /// so `MaterialApp` has a value if the platform requests light mode.
  static ThemeData light() => dark();

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
  /// into the canvas with a whisper of sage at the edge.
  static LinearGradient heroGradient(ColorScheme scheme) => const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF2A1E4A),
      _bg,
      Color(0xFF17221A),
    ],
    stops: [0.0, 0.55, 1.0],
  );
}
