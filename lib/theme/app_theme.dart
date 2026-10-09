import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'amp_tokens.dart';

/// Ampme's "Electric Club" Material 3 themes.
///
/// **Ink** (dark, the signature look): near-black canvas, volt-lime actions,
/// signal-orange alerts, Space Grotesk headlines over Inter UI text.
/// **Paper** (light): the same system on a warm off-white canvas with a
/// deeper volt that keeps contrast. `MaterialApp` picks via
/// `ThemeMode.system`; brand extras live in [AmpTokens].
class AppTheme {
  const AppTheme._();

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    tokens: AmpTokens.dark,
    surface: const Color(0xFF14141A),
    surfaceHigh: const Color(0xFF1C1C24),
    surfaceHighest: const Color(0xFF24242E),
    text: const Color(0xFFF4F4F0),
  );

  static ThemeData light() => _build(
    brightness: Brightness.light,
    tokens: AmpTokens.light,
    surface: const Color(0xFFFFFFFF),
    surfaceHigh: const Color(0xFFEDEBE3),
    surfaceHighest: const Color(0xFFE4E2D8),
    text: const Color(0xFF0B0B0F),
  );

  static ThemeData _build({
    required Brightness brightness,
    required AmpTokens tokens,
    required Color surface,
    required Color surfaceHigh,
    required Color surfaceHighest,
    required Color text,
  }) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: tokens.volt,
      onPrimary: tokens.onVolt,
      primaryContainer: tokens.volt.withValues(alpha: 0.16),
      onPrimaryContainer: text,
      secondary: tokens.signal,
      onSecondary: Colors.white,
      secondaryContainer: tokens.signal.withValues(alpha: 0.16),
      onSecondaryContainer: text,
      tertiary: tokens.syncWarn,
      onTertiary: tokens.onVolt,
      error: tokens.signal,
      onError: Colors.white,
      errorContainer: tokens.signal.withValues(alpha: 0.16),
      onErrorContainer: text,
      surface: surface,
      onSurface: text,
      onSurfaceVariant: tokens.textDim,
      surfaceContainerLowest: tokens.ink,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceHighest,
      outline: tokens.textDim.withValues(alpha: 0.6),
      outlineVariant: tokens.hairline,
      inverseSurface: isDark ? const Color(0xFFF4F4F0) : const Color(0xFF14141A),
      onInverseSurface: isDark ? const Color(0xFF0B0B0F) : const Color(0xFFF4F4F0),
      inversePrimary: isDark ? const Color(0xFF6E8A00) : const Color(0xFFD4FF3A),
      shadow: Colors.black,
      scrim: Colors.black,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: 'Inter',
    );

    TextStyle display(TextStyle? s, double size, {double spacing = -0.04}) =>
        (s ?? const TextStyle()).copyWith(
          fontFamily: AmpTokens.display,
          fontWeight: FontWeight.w700,
          fontSize: size,
          height: 0.98,
          letterSpacing: size * spacing,
          color: text,
        );

    final t = base.textTheme;
    final textTheme = t
        .copyWith(
          displayLarge: display(t.displayLarge, 64),
          displayMedium: display(t.displayMedium, 48),
          displaySmall: display(t.displaySmall, 38),
          headlineLarge: display(t.headlineLarge, 32, spacing: -0.03),
          headlineMedium: display(t.headlineMedium, 26, spacing: -0.02),
          headlineSmall: display(t.headlineSmall, 22, spacing: -0.02),
          titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
          titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.1),
          titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.2),
          labelSmall: t.labelSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 1.4),
        )
        .apply(bodyColor: text, displayColor: text);

    final stadium = const StadiumBorder();
    const buttonSize = Size.fromHeight(56);
    const buttonText = TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
    );

    return base.copyWith(
      scaffoldBackgroundColor: tokens.ink,
      canvasColor: tokens.ink,
      textTheme: textTheme,
      extensions: [tokens],
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: text,
        titleTextStyle: TextStyle(
          fontFamily: AmpTokens.display,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
          color: text,
        ),
        systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: tokens.glass,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AmpTokens.radiusCard),
          side: BorderSide(color: tokens.glassStroke),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: tokens.volt,
          foregroundColor: tokens.onVolt,
          disabledBackgroundColor: tokens.hairline,
          disabledForegroundColor: tokens.textDim,
          minimumSize: buttonSize,
          padding: const EdgeInsets.symmetric(horizontal: 28),
          shape: stadium,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: buttonSize,
          padding: const EdgeInsets.symmetric(horizontal: 28),
          side: BorderSide(color: tokens.glassStroke, width: 1.5),
          backgroundColor: tokens.glass,
          shape: stadium,
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: tokens.volt,
          shape: stadium,
          textStyle: buttonText.copyWith(fontSize: 15),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: text)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.glass,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        labelStyle: TextStyle(color: tokens.textDim),
        floatingLabelStyle: TextStyle(color: tokens.volt, fontWeight: FontWeight.w600),
        hintStyle: TextStyle(color: tokens.textDim.withValues(alpha: 0.7)),
        prefixIconColor: tokens.textDim,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AmpTokens.radiusField),
          borderSide: BorderSide(color: tokens.glassStroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AmpTokens.radiusField),
          borderSide: BorderSide(color: tokens.glassStroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AmpTokens.radiusField),
          borderSide: BorderSide(color: tokens.volt, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AmpTokens.radiusField),
          borderSide: BorderSide(color: tokens.signal),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: tokens.volt,
        inactiveTrackColor: tokens.hairline,
        thumbColor: tokens.volt,
        overlayColor: tokens.volt.withValues(alpha: 0.14),
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        valueIndicatorColor: tokens.volt,
        valueIndicatorTextStyle: TextStyle(color: tokens.onVolt, fontWeight: FontWeight.w700),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: tokens.volt,
        linearTrackColor: tokens.hairline,
        circularTrackColor: tokens.hairline,
        linearMinHeight: 4,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      dividerTheme: DividerThemeData(color: tokens.hairline, thickness: 1, space: 1),
      listTileTheme: ListTileThemeData(
        iconColor: tokens.textDim,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AmpTokens.radiusTile)),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: tokens.volt,
        collapsedIconColor: tokens.textDim,
        shape: const RoundedRectangleBorder(side: BorderSide.none),
        collapsedShape: const RoundedRectangleBorder(side: BorderSide.none),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: tokens.glass,
        side: BorderSide(color: tokens.glassStroke),
        shape: const StadiumBorder(),
        labelStyle: TextStyle(color: text, fontWeight: FontWeight.w600, fontSize: 13),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFFF4F4F0) : const Color(0xFF14141A),
        contentTextStyle: TextStyle(
          color: isDark ? const Color(0xFF0B0B0F) : const Color(0xFFF4F4F0),
          fontWeight: FontWeight.w600,
        ),
        actionTextColor: isDark ? const Color(0xFF6E8A00) : const Color(0xFFD4FF3A),
        shape: const StadiumBorder(),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AmpTokens.radiusCard)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? tokens.onVolt : tokens.textDim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? tokens.volt : tokens.hairline,
        ),
      ),
    );
  }
}
