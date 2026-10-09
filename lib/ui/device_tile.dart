import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';
import '../widgets/playing_indicator.dart';

/// One device in the room: an avatar that dances while it plays, its name,
/// a status line, and on the right a [SyncRing] (or any [trailing]).
/// [progress] shows a thin volt bar (e.g. while the song is copied over).
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.name,
    required this.status,
    this.playing = false,
    this.statusColor,
    this.trailing,
    this.progress,
    this.icon = Icons.smartphone_rounded,
  });

  final String name;
  final String status;
  final bool playing;
  final Color? statusColor;
  final Widget? trailing;
  final double? progress;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: AmpTokens.medium,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      decoration: BoxDecoration(
        color: tokens.glass,
        borderRadius: BorderRadius.circular(AmpTokens.radiusTile),
        border: Border.all(color: tokens.glassStroke),
      ),
      child: Column(
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: AmpTokens.medium,
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: playing ? tokens.volt : tokens.hairline,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: playing ? tokens.glow(tokens.volt, radius: 16) : const [],
                ),
                child: Center(
                  child: playing
                      ? PlayingIndicator(isPlaying: true, color: tokens.onVolt, size: 20)
                      : Icon(icon, size: 22, color: tokens.textDim),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: statusColor ?? tokens.textDim,
                        fontWeight: statusColor == null ? null : FontWeight.w600,
                        fontFeatures: AmpTokens.tabular,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 10), trailing!],
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
          ],
        ],
      ),
    );
  }
}
