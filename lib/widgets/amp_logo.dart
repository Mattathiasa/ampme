import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// Ampme's mark: a volt tile with five ink equalizer bars, glowing.
class AmpLogo extends StatelessWidget {
  const AmpLogo({super.key, this.size = 96});

  final double size;

  /// Bar heights, as fractions of the bar area (shared with the icon
  /// generator in `tool/generate_app_icon.dart`).
  static const List<double> bars = [0.42, 0.78, 1.0, 0.62, 0.34];

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tokens.volt,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: tokens.glow(tokens.volt, radius: size * 0.45),
      ),
      child: CustomPaint(painter: _BarsPainter(tokens.onVolt)),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromLTRB(
      size.width * 0.22,
      size.height * 0.24,
      size.width * 0.78,
      size.height * 0.76,
    );
    const n = 5;
    final w = area.width / (n * 1.6 - 0.6);
    final gap = w * 0.6;
    final paint = Paint()..color = color;
    for (var i = 0; i < n; i++) {
      final h = area.height * AmpLogo.bars[i];
      final x = area.left + i * (w + gap);
      final top = area.center.dy - h / 2;
      canvas.drawRRect(RRect.fromLTRBR(x, top, x + w, top + h, Radius.circular(w / 2)), paint);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.color != color;
}
