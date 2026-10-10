import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ampme/core/sync/acoustic_calibration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rate = 48000;

  /// A noisy "room" recording with chirp A at [aAt] and B at [bAt] (samples),
  /// over music-like noise.
  Float32List room({required int aAt, required int bAt, double noise = 0.3, int seed = 1}) {
    final rnd = math.Random(seed);
    final rec = Float32List(rate * 2);
    for (var i = 0; i < rec.length; i++) {
      rec[i] =
          (rnd.nextDouble() * 2 - 1) * noise +
          0.2 * math.sin(2 * math.pi * 220 * i / rate); // a "bass note"
    }
    final a = AcousticCalibration.chirp(rate, up: true);
    final b = AcousticCalibration.chirp(rate, up: false);
    for (var i = 0; i < a.length; i++) {
      rec[aAt + i] += a[i] * 0.4; // host is across the room: quieter
      rec[bAt + i] += b[i];
    }
    return rec;
  }

  test('finds both chirps within a sample, even over noise', () {
    final rec = room(aAt: 12000, bAt: 48000 + 7300);
    expect(AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: true)), 12000);
    expect(AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: false)), 55300);
  });

  test('host and device chirps are not confused', () {
    final rnd = math.Random(3);
    final rec = Float32List(rate);
    for (var i = 0; i < rec.length; i++) {
      rec[i] = (rnd.nextDouble() * 2 - 1) * 0.3;
    }
    final b = AcousticCalibration.chirp(rate, up: false);
    for (var i = 0; i < b.length; i++) {
      rec[20000 + i] += b[i];
    }
    expect(AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: true)), isNull);
    expect(AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: false)), 20000);
  });

  test('nothing there -> null', () {
    final rnd = math.Random(9);
    final rec = Float32List(rate);
    for (var i = 0; i < rec.length; i++) {
      rec[i] = (rnd.nextDouble() * 2 - 1) * 0.5;
    }
    expect(AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: true)), isNull);
  });

  test('a device 180 ms late gets a +180 ms nudge', () {
    // Players claimed A at 0 ms and B at 700 ms; B was really heard 880 ms
    // after A (its speaker path adds 180 ms the player didn't report).
    final rec = room(aAt: 4800, bAt: 4800 + 880 * rate ~/ 1000);
    final a = AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: true))!;
    final b = AcousticCalibration.find(rec, AcousticCalibration.chirp(rate, up: false))!;
    expect(
      AcousticCalibration.nudgeMs(heardA: a, heardB: b, sampleRate: rate, expectedGapMs: 700),
      180,
    );
    // And one that's 40 ms early.
    expect(
      AcousticCalibration.nudgeMs(
        heardA: 0,
        heardB: 660 * 48,
        sampleRate: rate,
        expectedGapMs: 700,
      ),
      -40,
    );
  });

  test('median ignores one bad run', () {
    expect(AcousticCalibration.median([170, 520, 182]), 182);
  });
}
