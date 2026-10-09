import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/amp_tokens.dart';
import 'pressable.dart';

enum AmpButtonKind {
  /// Volt pill with a neon glow — the one main action on a screen.
  primary,

  /// Glass pill — secondary actions.
  ghost,

  /// Signal-orange outline — ending or leaving.
  danger,
}

/// Ampme's button: a full-width pill that presses in and ticks the haptics.
///
/// Built on [FilledButton] / [OutlinedButton] so semantics, focus and
/// keyboard handling stay Material's (and tests can find it by type).
class AmpButton extends StatelessWidget {
  const AmpButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = AmpButtonKind.primary,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AmpButtonKind kind;

  /// Shows a spinner instead of the label (and disables the button).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final handler = onPressed;
    final enabled = handler != null && !busy;
    final VoidCallback? tap = enabled
        ? () {
            HapticFeedback.lightImpact();
            handler();
          }
        : null;

    final fg = switch (kind) {
      AmpButtonKind.primary => tokens.onVolt,
      AmpButtonKind.ghost => Theme.of(context).colorScheme.onSurface,
      AmpButtonKind.danger => tokens.signal,
    };
    final Widget content = busy
        ? SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: fg),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 10)],
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          );

    final Widget button = switch (kind) {
      AmpButtonKind.primary => FilledButton(onPressed: tap, child: content),
      AmpButtonKind.ghost => OutlinedButton(onPressed: tap, child: content),
      AmpButtonKind.danger => OutlinedButton(
        onPressed: tap,
        style: OutlinedButton.styleFrom(
          foregroundColor: tokens.signal,
          backgroundColor: tokens.signal.withValues(alpha: 0.08),
          side: BorderSide(color: tokens.signal.withValues(alpha: 0.6), width: 1.5),
        ),
        child: content,
      ),
    };

    return Pressable(
      enabled: enabled,
      child: AnimatedContainer(
        duration: AmpTokens.medium,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: kind == AmpButtonKind.primary && enabled
              ? tokens.glow(tokens.volt, radius: 28)
              : const [],
        ),
        child: button,
      ),
    );
  }
}
