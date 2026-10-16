import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// One device in the room: an avatar that lights up while it plays, its name,
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
    this.onRemove,
  });

  final String name;
  final String status;
  final bool playing;
  final Color? statusColor;
  final Widget? trailing;
  final double? progress;
  final IconData icon;

  /// When set, the tile gets a menu with "Remove from session".
  final VoidCallback? onRemove;

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
              ExcludeSemantics(
                child: AnimatedContainer(
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
                        ? Icon(Icons.graphic_eq_rounded, size: 24, color: tokens.onVolt)
                        : Icon(icon, size: 22, color: tokens.textDim),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: MergeSemantics(
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
              ),
              if (trailing != null) ...[const SizedBox(width: 10), trailing!],
              if (onRemove != null)
                PopupMenuButton<String>(
                  tooltip: 'Options for $name',
                  icon: Icon(Icons.more_vert_rounded, color: tokens.textDim),
                  onSelected: (_) => onRemove!(),
                  itemBuilder: (_) => const [
                    PopupMenuItem<String>(
                      value: 'remove',
                      child: Text('Remove from session'),
                    ),
                  ],
                ),
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
