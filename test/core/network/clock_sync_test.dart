import 'package:ampme/core/network/clock_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClockSyncSample', () {
    test('computes round trip and offset from a perfectly symmetric exchange', () {
      // Host clock is 500ms ahead of client clock; 100ms round trip.
      const sample = ClockSyncSample(t0: 1000, t1: 1550, t2: 1100);

      expect(sample.roundTripMs, 100);
      // offset = t1 - t0 - roundTrip/2 = 1550 - 1000 - 50 = 500
      expect(sample.offsetMs, 500);
    });

    test('handles a negative offset (client ahead of host)', () {
      const sample = ClockSyncSample(t0: 5000, t1: 4700, t2: 5040);

      expect(sample.roundTripMs, 40);
      expect(sample.offsetMs, -320);
    });

    test('handles zero round trip', () {
      const sample = ClockSyncSample(t0: 100, t1: 300, t2: 100);

      expect(sample.roundTripMs, 0);
      expect(sample.offsetMs, 200);
    });
  });

  group('ClockSyncEstimator', () {
    test('returns null before any sample is recorded', () {
      final estimator = ClockSyncEstimator();
      expect(estimator.currentEstimate, isNull);
    });

    test('returns the single sample directly when only one is recorded', () {
      final estimator = ClockSyncEstimator()
        ..addSample(const ClockSyncSample(t0: 0, t1: 210, t2: 20));

      final estimate = estimator.currentEstimate!;
      expect(estimate.roundTripMs, 20);
      expect(estimate.offsetMs, 200);
    });

    test('median offset of consistent samples matches the common value', () {
      final estimator = ClockSyncEstimator();
      // Five samples, all round trip 20ms, offset 100ms.
      for (var i = 0; i < 5; i++) {
        estimator.addSample(ClockSyncSample(t0: i * 100, t1: i * 100 + 110, t2: i * 100 + 20));
      }

      final estimate = estimator.currentEstimate!;
      expect(estimate.offsetMs, 100);
      expect(estimate.roundTripMs, 20);
    });

    test('discards high-latency outliers when estimating offset', () {
      final estimator = ClockSyncEstimator();

      // Four good samples: round trip 20ms, offset 100ms.
      for (var i = 0; i < 4; i++) {
        estimator.addSample(ClockSyncSample(t0: i * 1000, t1: i * 1000 + 110, t2: i * 1000 + 20));
      }
      // One bad sample: round trip 2000ms (WiFi hiccup), offset would be
      // wildly different (900ms) if it were allowed to count.
      estimator.addSample(const ClockSyncSample(t0: 5000, t1: 5900, t2: 7000));

      final estimate = estimator.currentEstimate!;
      // The outlier must not have dragged the offset toward 900.
      expect(estimate.offsetMs, 100);
    });

    test('respects maxSamples and evicts the oldest sample', () {
      final estimator = ClockSyncEstimator(maxSamples: 3);

      estimator.addSample(const ClockSyncSample(t0: 0, t1: 100000, t2: 0)); // huge outlier offset
      estimator.addSample(const ClockSyncSample(t0: 0, t1: 110, t2: 20));
      estimator.addSample(const ClockSyncSample(t0: 0, t1: 110, t2: 20));
      estimator.addSample(const ClockSyncSample(t0: 0, t1: 110, t2: 20));

      expect(estimator.sampleCount, 3);
      final estimate = estimator.currentEstimate!;
      // The first (huge-offset) sample should have been evicted.
      expect(estimate.offsetMs, 100);
    });

    test('reset clears accumulated samples', () {
      final estimator = ClockSyncEstimator()
        ..addSample(const ClockSyncSample(t0: 0, t1: 110, t2: 20));

      estimator.reset();

      expect(estimator.sampleCount, 0);
      expect(estimator.currentEstimate, isNull);
    });
  });
}
