import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../network/models/playback_state.dart';
import 'audio_engine.dart';
import 'live_pcm_player.dart';
import 'pcm_ring.dart';

/// Rings of live captures this page is receiving, by epoch, so the engine
/// can resolve an `ampme-live:<epoch>` URI (see `live_source_web.dart`).
final Map<int, PcmRing> liveRings = {};

/// [AudioEngine] for a live capture in the browser: a [LivePcmPlayer] whose
/// timeline is "position = wall time − start", so scheduling a start or
/// seeking is pure arithmetic and the position is exact (no polling grid).
class LiveWebEngine implements AudioEngine {
  web.AudioContext? _ctx;
  LivePcmPlayer? _player;
  double _volume = 1;
  int _pausedAtMs = 0;
  PlaybackState _state = PlaybackState.stopped;
  final _stateCtl = StreamController<PlaybackState>.broadcast();
  final _posCtl = StreamController<Duration>.broadcast();
  Timer? _posTimer;

  static bool handles(Uri uri) => uri.scheme == 'ampme-live';

  @override
  Future<Duration?> loadUrl(Uri uri, {required String title}) async {
    final ring = liveRings[int.parse(uri.path)];
    if (ring == null) throw StateError('No live audio for $uri');
    _player?.dispose();
    final ctx = _ctx ??= web.AudioContext();
    _player = LivePcmPlayer(ctx, ring)..volume = _volume;
    _setState(PlaybackState.paused);
    return null;
  }

  @override
  Future<Duration?> loadLocalFile(String path, {required String title}) =>
      throw UnsupportedError('LiveWebEngine plays live captures only');

  @override
  Future<void> prepareForStart(Duration position) async {
    _pausedAtMs = position.inMilliseconds;
  }

  @override
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero}) async {
    _startAt(at.millisecondsSinceEpoch - position.inMilliseconds);
  }

  void _startAt(int startWallMs) {
    final player = _player;
    if (player == null) return;
    unawaited(_resume());
    player.start(startWallMs);
    _setState(PlaybackState.playing);
    _posTimer ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_posCtl.isClosed) _posCtl.add(currentPosition);
    });
  }

  Future<void> _resume() async {
    final ctx = _ctx;
    if (ctx != null && ctx.state != 'running') {
      try {
        await ctx.resume().toDart;
      } catch (_) {}
    }
  }

  @override
  Future<void> play() async {
    // Called from a tap (browser autoplay unlock): resume the audio clock;
    // if we were playing on the shared timeline, keep that timeline.
    await _resume();
    final p = _player;
    if (p != null && !p.isPlaying) {
      _startAt(DateTime.now().millisecondsSinceEpoch - _pausedAtMs);
    }
  }

  @override
  Future<void> pause() async {
    _pausedAtMs = currentPosition.inMilliseconds;
    _player?.stop();
    _setState(PlaybackState.paused);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_player?.isPlaying ?? false) {
      _startAt(DateTime.now().millisecondsSinceEpoch - position.inMilliseconds);
    } else {
      _pausedAtMs = position.inMilliseconds;
    }
  }

  @override
  Duration estimatePositionAt(DateTime t) {
    final p = _player;
    if (p == null || !p.isPlaying) return Duration(milliseconds: _pausedAtMs);
    return Duration(milliseconds: p.positionAt(t.millisecondsSinceEpoch));
  }

  @override
  Duration get currentPosition => estimatePositionAt(DateTime.now());

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    _player?.volume = volume;
  }

  void _setState(PlaybackState s) {
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  PlaybackState get state => _state;

  @override
  Stream<Duration> get positionStream => _posCtl.stream;

  @override
  Stream<PlaybackState> get stateStream => _stateCtl.stream;

  @override
  Duration? get duration => null;

  @override
  Future<void> dispose() async {
    _posTimer?.cancel();
    _player?.dispose();
    _player = null;
    await _stateCtl.close();
    await _posCtl.close();
    final ctx = _ctx;
    _ctx = null;
    if (ctx != null) {
      try {
        await ctx.close().toDart;
      } catch (_) {}
    }
  }
}
