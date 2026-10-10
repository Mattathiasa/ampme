import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/audio/audio_engine.dart';
import '../sync_math.dart';
import 'video_fullscreen_button.dart';

/// The host's picture for a video track (Android/desktop app): a muted
/// player that follows the audio engine — the sound every device plays — so
/// picture and sound stay together. Small drift is absorbed by a ±5 %
/// playback-rate nudge, larger drift by a seek.
///
/// Full screen pushes a page that shows the same controller, so this view
/// (and its follow timer) keeps the picture on the sound underneath.
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
  bool _fullscreen = false;

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

  Future<void> _openFullscreen() async {
    if (_fullscreen || !_video.value.isInitialized) return;
    setState(() => _fullscreen = true);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, _, _) => _FullscreenVideoPage(video: _video),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const []);
    if (mounted) setState(() => _fullscreen = false);
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
          child: !v.isInitialized
              ? const Center(child: CircularProgressIndicator())
              // A texture can only be shown in one place at a time.
              : _fullscreen
              ? const SizedBox.expand()
              : GestureDetector(
                  onDoubleTap: _openFullscreen,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayer(_video),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: VideoFullscreenButton(onPressed: _openFullscreen),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// The picture alone on black, letterboxed to its aspect ratio. Tap shows or
/// hides the exit button; back (or the button) leaves.
class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({required this.video});

  final VideoPlayerController video;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  bool _showControls = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = widget.video.value.aspectRatio;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _showControls = !_showControls);
          if (_showControls) _scheduleHide();
        },
        onDoubleTap: () => Navigator.of(context).maybePop(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: ratio > 0 ? ratio : 16 / 9,
                child: VideoPlayer(widget.video),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: SafeArea(
                child: AnimatedOpacity(
                  opacity: _showControls ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: VideoFullscreenButton(
                      exit: true,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
