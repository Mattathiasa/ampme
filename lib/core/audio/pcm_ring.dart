import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

/// The last few minutes of a live audio capture, addressed by absolute frame
/// index (frame 0 = the first captured sample frame), interleaved 16-bit PCM.
///
/// Frames arrive from the host in order but possibly with gaps (a dropped
/// message); gaps read back as silence, as does anything older than the
/// buffer keeps.
class PcmRing {
  PcmRing({required this.channels, required this.sampleRate, int capacitySeconds = 120})
      : _capacity = sampleRate * capacitySeconds,
        _buf = Int16List(sampleRate * capacitySeconds * channels);

  final int channels;
  final int sampleRate;
  final int _capacity;
  final Int16List _buf;
  int _end = 0;
  bool _closed = false;
  final List<(int, Completer<void>)> _waiters = [];

  /// One past the newest frame received.
  int get endFrame => _end;

  /// Oldest frame still held.
  int get startFrame => math.max(0, _end - _capacity);

  bool get isClosed => _closed;

  /// Stores [samples] (interleaved) as frames starting at [startFrame].
  void write(int startFrame, Int16List samples) {
    if (_closed) return;
    final frames = samples.length ~/ channels;
    if (frames == 0) return;
    // Silence any gap between what we had and this block.
    if (startFrame > _end) _fill(_end, startFrame, null, 0);
    _fill(startFrame, startFrame + frames, samples, 0);
    if (startFrame + frames > _end) _end = startFrame + frames;
    _wake();
  }

  void _fill(int from, int to, Int16List? src, int srcFrame) {
    // Only the last `_capacity` frames matter.
    final lo = math.max(from, to - _capacity);
    for (var f = lo; f < to; f++) {
      final dst = (f % _capacity) * channels;
      final s = src == null ? -1 : (srcFrame + f - from) * channels;
      for (var c = 0; c < channels; c++) {
        _buf[dst + c] = s < 0 ? 0 : src![s + c];
      }
    }
  }

  /// Copies frames `[from, from + out.length / channels)` into [out];
  /// frames not (or no longer) held are silence.
  void read(int from, Int16List out) {
    final frames = out.length ~/ channels;
    final lo = startFrame;
    for (var i = 0; i < frames; i++) {
      final f = from + i;
      final o = i * channels;
      if (f < lo || f >= _end) {
        for (var c = 0; c < channels; c++) {
          out[o + c] = 0;
        }
      } else {
        final s = (f % _capacity) * channels;
        for (var c = 0; c < channels; c++) {
          out[o + c] = _buf[s + c];
        }
      }
    }
  }

  /// Completes once frame [frame] has arrived (or the ring is closed).
  Future<void> waitFor(int frame) {
    if (_closed || frame < _end) return Future.value();
    final c = Completer<void>();
    _waiters.add((frame, c));
    return c.future;
  }

  void _wake() {
    _waiters.removeWhere((w) {
      if (w.$1 < _end || _closed) {
        w.$2.complete();
        return true;
      }
      return false;
    });
  }

  void close() {
    _closed = true;
    _wake();
  }
}
