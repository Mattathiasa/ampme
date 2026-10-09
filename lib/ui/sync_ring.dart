import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// How far a device is from the room: a ring that closes as the drift
/// shrinks, coloured good / warn / bad, with the signed ms in the middle.
/// A null drift (not measured yet) shows a dim open ring and a dash.
class SyncRing extends StatelessWidget {
  const SyncRing({super.key, required this.driftMs, this.size = 48, this.stroke});

  final int? driftMs;
  final double size;
  final double? stroke;

  /// Ring fill for [driftMs]: 1 when spot on, 0 at 150 ms or more.
  static double closeness(int? driftMs) =>
      driftMs == null ? 0.0 : (1 - driftMs.abs() / 150).clamp(0.08, 1.0);

  static String signed(int ms) => ms > 0 ? '+$ms' : '$ms';

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final drift = driftMs;
    final color = tokens.syncColor(drift);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: closeness(drift)),
      duration: AmpTokens.slow,
      curve: AmpTokens.ease,
      builder: (context, fill, _) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(
            fill: fill,
            color: color,
            track: tokens.hairline,
            stroke: stroke ?? size * 0.09,
            glow: tokens.glowStrength,
          ),
          child: Center(
            child: FittedBox(
              child: Padding(
                padding: EdgeInsets.all(size * 0.26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      drift == null ? '—' : signed(drift),
                      style: TextStyle(
                        fontFamily: AmpTokens.mono,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        height: 1,
                        color: color,
                        fontFeatures: AmpTokens.tabular,
                      ),
                    ),
                    Text('ms', style: TextStyle(fontSize: 9, height: 1.2, color: tokens.textDim)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fill,
    required this.color,
    required this.track,
    required this.stroke,
    required this.glow,
  });

  final double fill;
  final Color color;
  final Color track;
  final double stroke;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2 + 1);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    final sweep = math.pi * 2 * fill;
    if (glow > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.8
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.25 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fill != fill || old.color != color || old.track != track;
}
