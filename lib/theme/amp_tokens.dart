import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Ampme's "Electric Club" design tokens that Material's [ColorScheme] has no
/// slot for: the volt/signal brand pair, sync-state colours, glass surfaces,
/// glow and motion. Read with `AmpTokens.of(context)`.
@immutable
class AmpTokens extends ThemeExtension<AmpTokens> {
  const AmpTokens({
    required this.volt,
    required this.onVolt,
    required this.signal,
    required this.ink,
    required this.textDim,
    required this.hairline,
    required this.glass,
    required this.glassStroke,
    required this.syncGood,
    required this.syncWarn,
    required this.syncBad,
    required this.glowStrength,
  });

  /// Brand accent: primary actions, live/active state, visualizer.
  final Color volt;
  final Color onVolt;

  /// Second accent: warnings, live-capture, destructive.
  final Color signal;

  /// The page canvas.
  final Color ink;
  final Color textDim;
  final Color hairline;

  /// Translucent card fill and its 1 px stroke.
  final Color glass;
  final Color glassStroke;

  final Color syncGood;
  final Color syncWarn;
  final Color syncBad;

  /// 0..1 — how much neon glow accents get (full in dark, subtle in light).
  final double glowStrength;

  // ---- Shared constants (theme-independent) ----

  static const double radiusCard = 28;
  static const double radiusTile = 20;
  static const double radiusField = 18;

  static const Duration fast = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 320);
  static const Duration slow = Duration(milliseconds: 560);
  static const Curve ease = Curves.easeOutCubic;
  static const Curve spring = Curves.easeOutBack;

  /// Display face (headlines, big numbers).
  static const String display = 'SpaceGrotesk';

  /// Monospace face (join codes, ms readouts).
  static const String mono = 'JetBrainsMono';

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static AmpTokens of(BuildContext context) => Theme.of(context).extension<AmpTokens>() ?? dark;

  /// Colour for a measured drift: good within 40 ms (what the host calls
  /// "in sync"), warn within 80 ms.
  Color syncColor(int? driftMs) {
    if (driftMs == null) return textDim;
    final d = driftMs.abs();
    if (d <= 40) return syncGood;
    if (d <= 80) return syncWarn;
    return syncBad;
  }

  /// Soft neon halo for [color] (buttons, live dots, the visualizer).
  List<BoxShadow> glow(Color color, {double radius = 24}) => [
    if (glowStrength > 0)
      BoxShadow(
        color: color.withValues(alpha: 0.35 * glowStrength),
        blurRadius: radius,
        spreadRadius: -4,
      ),
  ];

  static const dark = AmpTokens(
    volt: Color(0xFFD4FF3A),
    onVolt: Color(0xFF0B0B0F),
    signal: Color(0xFFFF4D2E),
    ink: Color(0xFF0B0B0F),
    textDim: Color(0xFF9A9AA6),
    hairline: Color(0xFF2A2A35),
    glass: Color(0x0FFFFFFF),
    glassStroke: Color(0x1FFFFFFF),
    syncGood: Color(0xFFD4FF3A),
    syncWarn: Color(0xFFFFB020),
    syncBad: Color(0xFFFF4D2E),
    glowStrength: 1,
  );

  static const light = AmpTokens(
    volt: Color(0xFF6E8A00),
    onVolt: Color(0xFFFFFFFF),
    signal: Color(0xFFE5391B),
    ink: Color(0xFFF4F3EE),
    textDim: Color(0xFF5F5F6B),
    hairline: Color(0xFFDAD8CF),
    glass: Color(0xB3FFFFFF),
    glassStroke: Color(0x1A0B0B0F),
    syncGood: Color(0xFF5B7A00),
    syncWarn: Color(0xFFB86E00),
    syncBad: Color(0xFFE5391B),
    glowStrength: 0.35,
  );

  @override
  AmpTokens copyWith({Color? volt, Color? signal}) => AmpTokens(
    volt: volt ?? this.volt,
    onVolt: onVolt,
    signal: signal ?? this.signal,
    ink: ink,
    textDim: textDim,
    hairline: hairline,
    glass: glass,
    glassStroke: glassStroke,
    syncGood: syncGood,
    syncWarn: syncWarn,
    syncBad: syncBad,
    glowStrength: glowStrength,
  );

  @override
  AmpTokens lerp(AmpTokens? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AmpTokens(
      volt: c(volt, other.volt),
      onVolt: c(onVolt, other.onVolt),
      signal: c(signal, other.signal),
      ink: c(ink, other.ink),
      textDim: c(textDim, other.textDim),
      hairline: c(hairline, other.hairline),
      glass: c(glass, other.glass),
      glassStroke: c(glassStroke, other.glassStroke),
      syncGood: c(syncGood, other.syncGood),
      syncWarn: c(syncWarn, other.syncWarn),
      syncBad: c(syncBad, other.syncBad),
      glowStrength: lerpDouble(glowStrength, other.glowStrength, t)!,
    );
  }
}
