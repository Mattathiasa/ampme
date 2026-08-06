import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:just_audio_background/just_audio_background.dart';

import '../network/models/playback_state.dart';
import '../../utils/id_generator.dart';
import 'audio_engine.dart';
import 'background_audio.dart';

/// `just_audio`/ExoPlayer-backed [AudioEngine].
///
/// The scheduling contract in [scheduleStart] deliberately separates
/// "getting ready" (seek, which can take a variable amount of time
/// depending on buffering) from "the audible instant" (calling `play()`),
/// firing the latter from a precise [Timer] so the only thing happening
/// at the target wall-clock moment is starting an already-buffered
/// player — this is what keeps devices tightly aligned.
class JustAudioEngine implements AudioEngine {
  final _player = ja.AudioPlayer();
  Timer? _scheduledTimer;

  @override
  Future<Duration?> loadLocalFile(String path, {required String title}) async {
    _scheduledTimer?.cancel();
    return _player.setAudioSource(_source(Uri.file(path), title));
  }

  @override
  Future<Duration?> loadUrl(Uri uri, {required String title}) async {
    _scheduledTimer?.cancel();
    return _player.setAudioSource(_source(uri, title));
  }

  /// Wraps a URI, tagging it with a [MediaItem] so `just_audio_background`
  /// can show a lock-screen/notification control and keep playback alive in
  /// the foreground service.
  ///
  /// The tag is only attached when [backgroundAudioReady] — attaching it
  /// while `just_audio_background` is uninitialized throws a
  /// `LateInitializationError` from its `_audioHandler`, which is what
  /// broke track loading. Without the tag playback still works; it just
  /// loses the lock-screen controls.
  ja.AudioSource _source(Uri uri, String title) {
    if (!backgroundAudioReady) {
      return ja.AudioSource.uri(uri);
    }
    return ja.AudioSource.uri(
      uri,
      tag: MediaItem(id: generateId(), title: title, album: 'Ampme'),
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero}) async {
    _scheduledTimer?.cancel();
    await _player.pause();

    final now = DateTime.now();
    final delay = at.difference(now);

    if (!delay.isNegative) {
      await _player.seek(position);
      _scheduledTimer = Timer(delay, () => _player.play());
      return;
    }

    // Target instant already passed (e.g. late join or delayed message):
    // catch up instead of starting from the stale position.
    final elapsedSincePosition = -delay;
    await _player.seek(position + elapsedSincePosition);
    await _player.play();
  }

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<PlaybackState> get stateStream => _player.playerStateStream.map(_mapState);

  @override
  Duration? get duration => _player.duration;

  PlaybackState _mapState(ja.PlayerState state) {
    if (state.processingState == ja.ProcessingState.loading ||
        state.processingState == ja.ProcessingState.buffering) {
      return PlaybackState.buffering;
    }
    if (state.processingState == ja.ProcessingState.idle ||
        state.processingState == ja.ProcessingState.completed) {
      return PlaybackState.stopped;
    }
    return state.playing ? PlaybackState.playing : PlaybackState.paused;
  }

  @override
  Future<void> dispose() async {
    _scheduledTimer?.cancel();
    await _player.dispose();
  }
}
