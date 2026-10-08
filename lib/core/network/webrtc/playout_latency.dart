/// Estimates how far a WebRTC *receiver's* audio trails the sender, from the
/// receiver's own `getStats()`:
///
///   network (half the round trip) + jitter buffer + one Opus frame (20 ms)
///
/// What stats can't see — the device's audio-output buffer (and Bluetooth) —
/// is left to the host's manual fine-tune. Values arrive as numbers in the
/// browser and as strings on Android, so everything is parsed leniently.
class PlayoutLatencyMeter {
  double? _lastJitterDelay; // seconds, cumulative
  double? _lastEmitted; // samples, cumulative

  /// Opus' frame duration: audio is packetized/decoded in 20 ms chunks.
  static const frameMs = 20.0;

  /// Feeds one `getStats()` snapshot ([reports] = each report's `type` and
  /// `values`). Returns the estimated latency in ms, or null when there's no
  /// inbound audio yet.
  int? update(Iterable<({String type, Map<dynamic, dynamic> values})> reports) {
    double? jitterDelay;
    double? emitted;
    double? rttSeconds;
    for (final r in reports) {
      final v = r.values;
      if (r.type == 'inbound-rtp' && (v['kind'] ?? v['mediaType']) == 'audio') {
        jitterDelay = _num(v['jitterBufferDelay']);
        emitted = _num(v['jitterBufferEmittedCount']);
      } else if (r.type == 'candidate-pair' &&
          v['state'] == 'succeeded' &&
          ('${v['nominated']}' == 'true' || v['selected'] == true)) {
        rttSeconds = _num(v['currentRoundTripTime']) ?? rttSeconds;
      }
    }
    if (jitterDelay == null || emitted == null || emitted <= 0) return null;

    // Average over the last interval (the buffer adapts); fall back to the
    // lifetime average on the first sample or if counters went backwards.
    final prevDelay = _lastJitterDelay;
    final prevEmitted = _lastEmitted;
    _lastJitterDelay = jitterDelay;
    _lastEmitted = emitted;
    double jitterMs;
    if (prevDelay != null &&
        prevEmitted != null &&
        emitted > prevEmitted &&
        jitterDelay >= prevDelay) {
      jitterMs = (jitterDelay - prevDelay) / (emitted - prevEmitted) * 1000;
    } else {
      jitterMs = jitterDelay / emitted * 1000;
    }
    final networkMs = (rttSeconds ?? 0) * 1000 / 2;
    return (jitterMs + networkMs + frameMs).round();
  }

  static double? _num(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}

/// Smooths latency reports so the host's speaker delay doesn't wobble:
/// exponential moving average weighting the newest report by [alpha].
int smoothLatency(int? previous, int sample, {double alpha = 0.3}) =>
    previous == null ? sample : (previous + alpha * (sample - previous)).round();
