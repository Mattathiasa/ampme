import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/audio/audio_engine.dart';
import '../sync_math.dart';

/// The host's picture for a video track (Android/desktop app): a muted
/// player that follows the audio engine — the sound every device plays — so
/// picture and sound stay together. Small drift is absorbed by a ±5 %
/// playback-rate nudge, larger drift by a seek.
class NativeVideoView extends StatefulWidget {
  const NativeVideoView({
    super.key,
    required this.path,
    required this.engine,
    required this.playing,
  });

  final String path;
  final AudioEngine engine;
  final bool playing;

  @override
  State<NativeVideoView> createState() => _NativeVideoViewState();
}

class _NativeVideoViewState extends State<NativeVideoView> {
  late VideoPlayerController _video;
  Timer? _sync;
  double _rate = 1;

  @override
  void initState() {
    super.initState();
    _open();
  }

  void _open() {
    _video = VideoPlayerController.file(
      File(widget.path),
      // The sound comes from the audio engine; never take audio focus.
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _video.initialize().then((_) async {
      await _video.setVolume(0);
      if (mounted) setState(() {});
    });
    _sync = Timer.periodic(const Duration(milliseconds: 250), (_) => _follow());
  }

  @override
  void didUpdateWidget(NativeVideoView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _sync?.cancel();
      unawaited(_video.dispose());
      _open();
    }
  }

  Future<void> _follow() async {
    final v = _video.value;
    if (!v.isInitialized) return;
    final target = widget.engine.estimatePositionAt(DateTime.now());
    final drift = v.position.inMilliseconds - target.inMilliseconds;
    if (!widget.playing) {
      if (v.isPlaying) await _video.pause();
      if (drift.abs() > 100) await _video.seekTo(target);
      return;
    }
    if (!v.isPlaying) {
      await _video.seekTo(target);
      await _video.play();
      return;
    }
    final fix = videoCorrection(drift);
    if (fix.seek) {
      await _video.seekTo(target + const Duration(milliseconds: 60));
    } else if ((fix.rate - _rate).abs() > 0.004) {
      _rate = fix.rate;
      await _video.setPlaybackSpeed(fix.rate);
    }
  }

  @override
  void dispose() {
    _sync?.cancel();
    unawaited(_video.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video.value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: Colors.black,
        child: AspectRatio(
          aspectRatio: v.isInitialized && v.aspectRatio > 0 ? v.aspectRatio : 16 / 9,
          child: v.isInitialized
              ? VideoPlayer(_video)
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }
}
