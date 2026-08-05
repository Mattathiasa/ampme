/// One NTP-style clock-sync round trip:
/// - [t0] client's local time when the request was sent
/// - [t1] host's local time when it replied
/// - [t2] client's local time when the reply arrived
///
/// Assumes the outbound and return legs of the round trip take roughly
/// equal time, which is the standard NTP approximation.
class ClockSyncSample {
  const ClockSyncSample({required this.t0, required this.t1, required this.t2});

  final int t0;
  final int t1;
  final int t2;

  /// Total time the round trip took, measured on the client's clock.
  int get roundTripMs => t2 - t0;

  /// Estimated `hostClock - clientClock` at the moment this sample was
  /// taken: the host's reply timestamp, minus the client send time, minus
  /// half the round trip (the estimated one-way network delay).
  int get offsetMs => t1 - t0 - (roundTripMs ~/ 2);
}

/// Estimated clock offset for a session, along with how it was derived.
class ClockSyncEstimate {
  const ClockSyncEstimate({required this.offsetMs, required this.roundTripMs});

  final int offsetMs;
  final int roundTripMs;
}

/// Accumulates [ClockSyncSample]s from repeated round trips and derives a
/// robust offset estimate.
///
/// WiFi round trips are noisy: an occasional sample gets delayed by
/// contention or a GC pause and its offset is unreliable. To resist that,
/// [currentEstimate] keeps only the lowest-latency half of recent samples
/// (best-observed round trips are the ones least distorted by queuing
/// delay) and takes the median offset among those.
class ClockSyncEstimator {
  ClockSyncEstimator({this.maxSamples = 32});

  final int maxSamples;
  final List<ClockSyncSample> _samples = [];

  void addSample(ClockSyncSample sample) {
    _samples.add(sample);
    if (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
  }

  void reset() => _samples.clear();

  int get sampleCount => _samples.length;

  /// Returns null if no samples have been recorded yet.
  ClockSyncEstimate? get currentEstimate {
    if (_samples.isEmpty) return null;

    final sorted = List<ClockSyncSample>.from(_samples)
      ..sort((a, b) => a.roundTripMs.compareTo(b.roundTripMs));

    final keepCount = (sorted.length / 2).ceil().clamp(1, sorted.length);
    final best = sorted.sublist(0, keepCount);

    final offsets = best.map((s) => s.offsetMs).toList()..sort();
    final medianOffset = _median(offsets);
    final medianRoundTrip = _median(best.map((s) => s.roundTripMs).toList()..sort());

    return ClockSyncEstimate(offsetMs: medianOffset, roundTripMs: medianRoundTrip);
  }

  static int _median(List<int> sortedValues) {
    final n = sortedValues.length;
    if (n.isOdd) return sortedValues[n ~/ 2];
    return ((sortedValues[n ~/ 2 - 1] + sortedValues[n ~/ 2]) / 2).round();
  }
}
