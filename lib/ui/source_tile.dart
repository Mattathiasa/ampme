import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/amp_tokens.dart';
import 'pressable.dart';

/// A big tappable choice of what the room plays (song, browser tab, device
/// audio, mic): icon block, title and a one-line hint. [active] lights it up.
///
/// An [OutlinedButton] underneath, so it is a real button to assistive tech
/// (and to the e2e tests, which click it by its title).
class SourceTile extends StatelessWidget {
  const SourceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.active = false,
    this.accent,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onPressed;
  final bool active;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final theme = Theme.of(context);
    final color = accent ?? tokens.volt;
    final enabled = onPressed != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        enabled: enabled,
        scale: 0.98,
        child: OutlinedButton(
          onPressed: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onPressed!();
                }
              : null,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(72),
            padding: const EdgeInsets.all(12),
            alignment: Alignment.centerLeft,
            backgroundColor: active ? color.withValues(alpha: 0.10) : tokens.glass,
            side: BorderSide(
              color: active ? color.withValues(alpha: 0.7) : tokens.glassStroke,
              width: active ? 1.5 : 1,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AmpTokens.radiusTile),
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: AmpTokens.medium,
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: active ? color : color.withValues(alpha: enabled ? 0.14 : 0.06),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: active ? tokens.onVolt : (enabled ? color : tokens.textDim),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: enabled ? theme.colorScheme.onSurface : tokens.textDim,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.textDim),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                active ? Icons.graphic_eq_rounded : Icons.chevron_right_rounded,
                color: active ? color : tokens.textDim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
