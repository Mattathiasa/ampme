import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;

import '../network/models/playback_state.dart';
import '../observability/reporting.dart';
import 'audio_engine.dart';
import 'audio_session_manager.dart';

/// `just_audio`/ExoPlayer-backed [AudioEngine].
///
/// The scheduling contract in [scheduleStart] deliberately separates
/// "getting ready" (seek, which can take a variable amount of time
/// depending on buffering) from "the audible instant" (calling `play()`),
/// firing the latter from a precise [Timer] so the only thing happening
/// at the target wall-clock moment is starting an already-buffered
/// player — this is what keeps devices tightly aligned.
class JustAudioEngine implements AudioEngine {
  late final ja.AudioPlayer _player = ja.AudioPlayer(
    handleInterruptions: !quiet,
    handleAudioSessionActivation: !quiet,
    // ExoPlayer's stock defaults require ~2.5s of audio buffered before it
    // starts producing sound. On a joined device that entire buffering
    // window lands after the scheduled start instant — the dominant cause of
    // the "host is a second+ ahead of me" lag. Shrinking the playback-start
    // threshold to 300ms makes readiness (and therefore the synchronized
    // start) land within tens of ms of target; on the same LAN the smaller
    // buffer fills in a few ms and playback is still stall-free.
    audioLoadConfiguration: const ja.AudioLoadConfiguration(
      androidLoadControl: ja.AndroidLoadControl(
        bufferForPlaybackDuration: Duration(milliseconds: 300),
        bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 1200),
        minBufferDuration: Duration(seconds: 30),
        maxBufferDuration: Duration(seconds: 60),
      ),
    ),
  );
  Timer? _scheduledTimer;

  /// The most recent position update and the wall-clock instant it was
  /// observed at (the platform sends updates on a coarse grid — ≈250ms on
  /// Android — so a raw [currentPosition] paired with a fresh timestamp is
  /// systematically stale). [estimatePositionAt] extrapolates from this pair.
  Duration _lastPosition = Duration.zero;
  DateTime _lastPositionAt = DateTime.now();
  bool _playing = false;
  double _speed = 1;

  /// A side player (e.g. the host's calibration chirp) that must not take
  /// audio focus or react to interruptions — focus changes would make the
  /// main player, and so the whole session, pause.
  final bool quiet;

  JustAudioEngine({this.quiet = false}) {
    // Configure the app-wide audio session (focus + interruptions). just_audio
    // pauses/resumes the player itself on interruption via its built-in
    // handleInterruptions behavior; the manager's events additionally let the
    // host broadcast pause/play to listeners for sync integrity.
    _setupAudioSession();

    // Track the freshest playhead and playback state so drift measurement
    // can extrapolate a timestamp-consistent position instead of using the
    // last polled value (which can lag reality by a full poll interval).
    _player.positionStream.listen((position) {
      _lastPosition = position;
      _lastPositionAt = DateTime.now();
    });
    _player.playerStateStream.listen((state) {
      _playing = state.playing;
    });
  }

  Future<void> _setupAudioSession() async {
    try {
      await AudioSessionManager.instance.ensureConfigured();
    } catch (e, st) {
      // Audio focus is best-effort: without it playback still works, it just
      // won't duck/pause for other apps.
      reportError(e, st, context: 'configure audio session');
    }
  }

  @override
  Future<Duration?> loadLocalFile(String path, {required String title}) async {
    _scheduledTimer?.cancel();
    await setSpeed(1);
    return _player.setAudioSource(_source(Uri.file(path), title));
  }

  @override
  Future<Duration?> loadUrl(Uri uri, {required String title}) async {
    _scheduledTimer?.cancel();
    await setSpeed(1);
    return _player.setAudioSource(_source(uri, title));
  }

  // [title] is unused on this engine (there is no media notification).
  ja.AudioSource _source(Uri uri, String title) => ja.AudioSource.uri(uri);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> prepareForStart(Duration position) async {
    // Pause first: if this runs while the player is audibly playing (a seek
    // command re-buffering mid-song), seeking without pausing would make the
    // device keep playing from the new position on its own, and the follow-up
    // scheduled start would then sound like a double-start. The host sends
    // the audible start separately, so being paused here is always correct.
    await _player.pause();
    // Best-effort pre-buffering: seek to where playback will begin and wait
    // until the player reports ready, so a later scheduled start is
    // instantaneous. The timeout is generous — a slow first fetch must never
    // wedge the listener, and [scheduleStart] re-checks readiness anyway.
    await _player.seek(position);
    await _waitUntilReady(const Duration(seconds: 8));
  }

  @override
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero}) async {
    _scheduledTimer?.cancel();
    await _player.pause();

    final now = DateTime.now();
    final delay = at.difference(now);

    if (!delay.isNegative) {
      await _player.seek(position);
      // Wait (bounded by the remaining lead) until the player is actually
      // ready to emit audio — ExoPlayer's `ready` state means its playback-
      // start buffer threshold is met, so the play() below produces sound
      // immediately and the audible start lands on the wall-clock instant
      // [at] instead of lagging behind by buffering time. This is what keeps
      // the host and joined devices' first audible samples aligned.
      await _waitUntilReady(delay);

      final remaining = at.difference(DateTime.now());
      if (!remaining.isNegative) {
        _scheduledTimer = Timer(remaining, () => _player.play());
        return;
      }
      // Buffering consumed the whole lead; fall through to catch-up so the
      // content position stays aligned with the host.
    }

    // Target instant already passed (late join, delayed message, or slow
    // buffer): catch up instead of starting from the stale position.
    final elapsedSincePosition = at.difference(DateTime.now());
    await _player.seek(position - elapsedSincePosition);
    await _player.play();
  }

  /// Waits up to [timeout] for the player to reach `ready` (i.e. to have
  /// buffered past its playback-start threshold). Returns as soon as it is;
  /// a player that's already ready returns immediately.
  Future<void> _waitUntilReady(Duration timeout) async {
    if (timeout <= Duration.zero) return;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_player.processingState == ja.ProcessingState.ready) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  @override
  Duration estimatePositionAt(DateTime t) {
    // Only extrapolate while audibly playing: while paused the playhead is
    // frozen, and during a rebuffer stall just_audio keeps `playing` true
    // while the audio (and the true playhead) is actually stalled — both
    // would make extrapolation overshoot.
    if (!_playing ||
        _player.processingState != ja.ProcessingState.ready) {
      return _lastPosition;
    }
    final elapsed = t.difference(_lastPositionAt);
    if (elapsed <= Duration.zero) return _lastPosition;
    return _lastPosition + elapsed * _speed;
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (speed == _speed) return;
    // Re-anchor so extrapolation switches rate exactly now.
    final now = DateTime.now();
    _lastPosition = estimatePositionAt(now);
    _lastPositionAt = now;
    _speed = speed;
    await _player.setSpeed(speed);
  }

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Duration get currentPosition => _player.position;

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
