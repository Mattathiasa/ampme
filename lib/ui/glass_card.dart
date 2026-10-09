import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// A translucent card with a hairline stroke and a faint top-left sheen.
/// [accent] tints the stroke and sheen (e.g. the live card). No shadows:
/// under a translucent fill they'd show through as a muddy tint.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.accent,
    this.radius = AmpTokens.radiusCard,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? accent;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final accent = this.accent;
    return AnimatedContainer(
      duration: AmpTokens.medium,
      curve: AmpTokens.ease,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: tokens.glass,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              (accent ?? Colors.white).withValues(alpha: 0.03 * tokens.glowStrength + 0.02),
              tokens.glass,
            ),
            tokens.glass,
          ],
        ),
        border: Border.all(
          color: accent?.withValues(alpha: 0.55) ?? tokens.glassStroke,
          width: accent == null ? 1 : 1.5,
        ),
      ),
      child: child,
    );
  }
}

/// Small uppercase, letter-spaced heading above a group, with an optional
/// count chip ("SPEAKERS · 4").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.count, this.trailing});

  final String text;
  final int? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(color: tokens.textDim);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Text(text.toUpperCase(), style: style),
          if (count != null) ...[
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: AmpTokens.medium,
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Container(
                key: ValueKey(count),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: tokens.volt,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: tokens.onVolt,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    fontFeatures: AmpTokens.tabular,
                  ),
                ),
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// The page canvas: ink with two faint static light blooms (volt top-right,
/// signal bottom-left) so glass cards have something to sit on.
class AmpBackground extends StatelessWidget {
  const AmpBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final a = 0.10 * tokens.glowStrength + 0.03;
    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.ink),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(1.1, -1.0),
            radius: 1.2,
            colors: [
              tokens.volt.withValues(alpha: a),
              tokens.volt.withValues(alpha: 0),
            ],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-1.2, 1.1),
              radius: 1.1,
              colors: [
                tokens.signal.withValues(alpha: a * 0.8),
                tokens.signal.withValues(alpha: 0),
              ],
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
