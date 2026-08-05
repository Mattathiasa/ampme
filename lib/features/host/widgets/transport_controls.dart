import 'package:flutter/material.dart';

import '../../../core/network/models/playback_state.dart';
import '../../../utils/formatters.dart';

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
    this.onPlay,
    this.onPause,
    this.onSeek,
    this.onVolumeChanged,
    this.volume,
  });

  final PlaybackState playbackState;
  final Duration position;
  final Duration duration;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<double>? onVolumeChanged;
  final double? volume;

  @override
  Widget build(BuildContext context) {
    final durationMs = duration.inMilliseconds.clamp(1, double.maxFinite.toInt());
    final positionMs = position.inMilliseconds.clamp(0, durationMs);
    final seekHandler = onSeek;
    final playHandler = onPlay;
    final pauseHandler = onPause;

    return Column(
      children: [
        Slider(
          value: positionMs.toDouble(),
          max: durationMs.toDouble(),
          onChanged: seekHandler == null
              ? null
              : (value) => seekHandler(Duration(milliseconds: value.round())),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(formatDuration(position)),
            Text(formatDuration(duration)),
          ],
        ),
        const SizedBox(height: 8),
        IconButton.filled(
          iconSize: 48,
          onPressed: playbackState == PlaybackState.playing ? pauseHandler : playHandler,
          icon: Icon(
            playbackState == PlaybackState.playing ? Icons.pause : Icons.play_arrow,
          ),
        ),
        if (volume != null)
          Row(
            children: [
              const Icon(Icons.volume_down),
              Expanded(
                child: Slider(value: volume!, onChanged: onVolumeChanged),
              ),
              const Icon(Icons.volume_up),
            ],
          ),
      ],
    );
  }
}
