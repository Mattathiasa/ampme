import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'pcm_ring.dart';

/// Plays a live [PcmRing] through WebAudio so that frame `f` is heard at
/// wall-clock time `startWallMs + f / sampleRate`. Used by the web host for
/// its own speaker and by browser listeners: everyone schedules against the
/// same (clock-synced) wall time, so everyone hears the same frame together.
///
/// Chunks are queued back-to-back on the audio clock (sample-exact, no
/// clicks); the wall↔audio-clock mapping is only re-anchored if it drifts by
/// more than [_resyncThreshold].
class LivePcmPlayer {
  LivePcmPlayer(this.ctx, this.ring, {web.AudioNode? destination})
      : _out = ctx.createGain() {
    _out.connect(destination ?? ctx.destination);
  }

  final web.BaseAudioContext ctx;
  final PcmRing ring;
  final web.GainNode _out;

  static const double _chunkSeconds = 0.05;
  static const double _horizonSeconds = 0.35;
  static const double _resyncThreshold = 0.02;

  int? _startWallMs;
  int? _nextFrame;
  double _nextCtxTime = 0;
  Timer? _timer;
  final List<web.AudioBufferSourceNode> _scheduled = [];

  bool get isPlaying => _timer != null;

  set volume(double v) => _out.gain.value = v;

  /// Wall time (ms since epoch) at which frame 0 is (or would be) heard.
  int? get startWallMs => _startWallMs;

  void start(int startWallMs) {
    stop();
    _startWallMs = startWallMs;
    _nextFrame = null;
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => _tick());
    _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final s in _scheduled) {
      try {
        s.stop();
        s.disconnect();
      } catch (_) {}
    }
    _scheduled.clear();
  }

  /// Position (ms into the capture) heard at wall time [wallMs].
  int positionAt(int wallMs) => math.max(0, wallMs - (_startWallMs ?? wallMs));

  int _frameAtWall(double wallMs) =>
      ((wallMs - _startWallMs!) * ring.sampleRate / 1000).floor();

  double _wallOfFrame(int frame) => _startWallMs! + frame * 1000 / ring.sampleRate;

  void _tick() {
    final start = _startWallMs;
    if (start == null) return;
    final ctxNow = ctx.currentTime;
    final wallNow = DateTime.now().millisecondsSinceEpoch.toDouble();
    double idealCtx(int frame) => ctxNow + (_wallOfFrame(frame) - wallNow) / 1000;

    var next = _nextFrame;
    if (next == null || (_nextCtxTime - idealCtx(next)).abs() > _resyncThreshold) {
      // (Re)anchor: next chunk starts where the wall clock says it should.
      next = math.max(0, _frameAtWall(wallNow + 20));
      _nextCtxTime = idealCtx(next);
    }
    final chunk = (ring.sampleRate * _chunkSeconds).round();
    while (_nextCtxTime < ctxNow + _horizonSeconds) {
      if (_nextCtxTime < ctxNow + 0.005) {
        // Fell behind (tab throttled, data late): jump to the present.
        next = math.max(0, _frameAtWall(wallNow + 20));
        _nextCtxTime = idealCtx(next);
        continue;
      }
      final available = ring.endFrame - next!;
      if (available <= 0) break; // wait for audio to arrive
      final n = math.min(chunk, available);
      _schedule(next, n, _nextCtxTime);
      next += n;
      _nextCtxTime += n / ring.sampleRate;
    }
    _nextFrame = next;
    // Old chunks have finished; only recent ones may need stopping.
    if (_scheduled.length > 64) _scheduled.removeRange(0, _scheduled.length - 64);
  }

  void _schedule(int frame, int frames, double when) {
    final channels = ring.channels;
    final buffer = ctx.createBuffer(channels, frames, ring.sampleRate.toDouble());
    final pcm = Int16List(frames * channels);
    ring.read(frame, pcm);
    final plane = Float32List(frames);
    for (var c = 0; c < channels; c++) {
      for (var i = 0; i < frames; i++) {
        plane[i] = pcm[i * channels + c] / 32768;
      }
      buffer.copyToChannel(plane.toJS, c);
    }
    final src = ctx.createBufferSource()
      ..buffer = buffer
      ..connect(_out);
    src.start(when);
    _scheduled.add(src);
  }

  void dispose() {
    stop();
    try {
      _out.disconnect();
    } catch (_) {}
  }
}
