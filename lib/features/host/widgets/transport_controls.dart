import 'package:flutter/material.dart';

import '../../../core/network/models/playback_state.dart';
import '../../../utils/formatters.dart';
import '../../../widgets/playing_indicator.dart';

/// Transport UI shared by the host (interactive) and listener (read-only
/// mirror of the host's playback) screens. Passing `null` for a callback
/// disables the corresponding control instead of leaving it tappable but
/// inert.
class TransportControls extends StatelessWidget {
  const TransportControls({
    super.key,
    required this.playbackState,
    required this.position,
    required this.duration,
    this.title,
    this.onPlay,
    this.onPause,
    this.onSeek,
    this.onVolumeChanged,
    this.volume,
  });

  final PlaybackState playbackState;
  final Duration position;
  final Duration duration;
  final String? title;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<double>? onVolumeChanged;
  final double? volume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final durationMs = duration.inMilliseconds.clamp(1, double.maxFinite.toInt());
    final positionMs = position.inMilliseconds.clamp(0, durationMs);
    final seekHandler = onSeek;
    final playHandler = onPlay;
    final pauseHandler = onPause;
    final isPlaying = playbackState == PlaybackState.playing;
    final isBuffering = playbackState == PlaybackState.buffering;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Row(
            children: [
              PlayingIndicator(isPlaying: isPlaying, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isBuffering)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: positionMs.toDouble(),
            max: durationMs.toDouble(),
            onChanged: seekHandler == null
                ? null
                : (value) => seekHandler(Duration(milliseconds: value.round())),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatDuration(position), style: theme.textTheme.labelMedium),
              Text(formatDuration(duration), style: theme.textTheme.labelMedium),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: (playHandler == null && pauseHandler == null)
                  ? null
                  : LinearGradient(
                      colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
                    ),
              color: (playHandler == null && pauseHandler == null)
                  ? scheme.surfaceContainerHighest
                  : null,
            ),
            child: IconButton(
              iconSize: 44,
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              onPressed: isPlaying ? pauseHandler : playHandler,
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            ),
          ),
        ),
        if (volume != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.volume_down, color: scheme.onSurfaceVariant),
              Expanded(
                child: Slider(
                  value: volume!.clamp(0.0, 1.0),
                  onChanged: onVolumeChanged,
                ),
              ),
              Icon(Icons.volume_up, color: scheme.onSurfaceVariant),
            ],
          ),
        ],
      ],
    );
  }
}
