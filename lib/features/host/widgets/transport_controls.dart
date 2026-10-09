import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/network/models/playback_state.dart';
import '../../../theme/amp_tokens.dart';
import '../../../ui/eq_visualizer.dart';
import '../../../ui/pressable.dart';
import '../../../utils/formatters.dart';

/// Now-playing panel shared by the host (interactive) and listener (read-only
/// mirror of the host's playback) screens: visualizer, title, scrubber and a
/// big play button. Passing `null` for a callback disables the corresponding
/// control instead of leaving it tappable but inert.
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
    this.spectrum,
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

  /// Real audio levels for the visualizer (the browser host); otherwise the
  /// bars follow a synthetic beat while playing.
  final SpectrumSampler? spectrum;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    final durationMs = duration.inMilliseconds.clamp(1, double.maxFinite.toInt());
    final positionMs = position.inMilliseconds.clamp(0, durationMs);
    final seekHandler = onSeek;
    final isPlaying = playbackState == PlaybackState.playing;
    final isBuffering = playbackState == PlaybackState.buffering;
    final interactive = onPlay != null || onPause != null;
    final times = theme.textTheme.labelMedium?.copyWith(
      color: tokens.textDim,
      fontFamily: AmpTokens.mono,
      fontFeatures: AmpTokens.tabular,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EqVisualizer(playing: isPlaying, spectrum: spectrum, height: 64),
        const SizedBox(height: 18),
        if (title != null)
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isBuffering ? 'BUFFERING' : (isPlaying ? 'NOW PLAYING' : 'READY'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isPlaying ? tokens.volt : tokens.textDim,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
              if (isBuffering)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        const SizedBox(height: 8),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 5,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: seekHandler == null ? 0 : 8),
            disabledActiveTrackColor: tokens.volt,
            disabledInactiveTrackColor: tokens.hairline,
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
              Text(formatDuration(position), style: times),
              Text(formatDuration(duration), style: times),
            ],
          ),
        ),
        if (interactive) ...[
          const SizedBox(height: 10),
          Center(
            child: _PlayButton(isPlaying: isPlaying, onPlay: onPlay, onPause: onPause),
          ),
        ],
        if (volume != null) ...[
          const SizedBox(height: 10),
          VolumeRow(volume: volume!, onChanged: onVolumeChanged),
        ],
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.isPlaying, this.onPlay, this.onPause});

  final bool isPlaying;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final handler = isPlaying ? onPause : onPlay;
    return Pressable(
      enabled: handler != null,
      scale: 0.9,
      child: AnimatedContainer(
        duration: AmpTokens.medium,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: handler == null ? tokens.hairline : tokens.volt,
          boxShadow: handler == null ? const [] : tokens.glow(tokens.volt, radius: 30),
        ),
        child: IconButton(
          iconSize: 40,
          padding: const EdgeInsets.all(16),
          color: tokens.onVolt,
          tooltip: isPlaying ? 'Pause' : 'Play',
          onPressed: handler == null
              ? null
              : () {
                  HapticFeedback.mediumImpact();
                  handler();
                },
          icon: AnimatedSwitcher(
            duration: AmpTokens.fast,
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey(isPlaying),
            ),
          ),
        ),
      ),
    );
  }
}

/// This device's volume: a slider between two speaker icons.
class VolumeRow extends StatelessWidget {
  const VolumeRow({super.key, required this.volume, this.onChanged});

  final double volume;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final dim = AmpTokens.of(context).textDim;
    return Row(
      children: [
        Icon(Icons.volume_mute_rounded, color: dim, size: 20),
        Expanded(
          child: Slider(value: volume.clamp(0.0, 1.0), onChanged: onChanged),
        ),
        Icon(Icons.volume_up_rounded, color: dim, size: 20),
      ],
    );
  }
}
