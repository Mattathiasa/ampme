import 'dart:math' as math;
import 'dart:typed_data';

/// Acoustic sync calibration: how much later this device's speaker sounds
/// than the host's, measured with this device's microphone.
///
/// The host plays chirp A at an agreed instant; this device plays chirp B
/// through its own playback path a moment later; one mic recording catches
/// both. Mic input latency and the recording's start time cancel out because
/// only the *gap* between the two arrivals is used:
///
///     error = (tB_heard − tA_heard) − (tB_expected − tA_expected)
///
/// where "expected" is when each player *reports* the chirp was audible.
/// A positive error means this device sounds late by that much — exactly the
/// sync nudge it needs.
class AcousticCalibration {
  const AcousticCalibration._();

  /// Chirp length. Long enough for a clear correlation peak over music,
  /// short enough to be a "blip".
  static const int chirpMs = 80;

  /// A Hann-windowed rising sweep. The host's (A, [up] true) and this
  /// device's (B) use separate bands — 1.5–3.5 kHz and 4.5–7 kHz — so one can
  /// never be mistaken for the other, and both sit where phone speakers and
  /// mics are good.
  static Float32List chirp(int sampleRate, {required bool up}) {
    final n = sampleRate * chirpMs ~/ 1000;
    final out = Float32List(n);
    final f0 = up ? 1500.0 : 4500.0;
    final f1 = up ? 3500.0 : 7000.0;
    final k = (f1 - f0) / (n / sampleRate);
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final phase = 2 * math.pi * (f0 * t + 0.5 * k * t * t);
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
      out[i] = (math.sin(phase) * w * 0.9).toDouble();
    }
    return out;
  }

  /// Where [template] starts in [recording] (sample index), or null if it
  /// isn't clearly there. "Clearly" = the correlation peak stands
  /// [minProminence]× above the typical correlation level.
  static int? find(Float32List recording, Float32List template, {double minProminence = 8}) {
    if (recording.length < template.length) return null;
    final corr = _crossCorrelate(recording, template);
    var best = 0;
    var bestVal = 0.0;
    for (var i = 0; i <= recording.length - template.length; i++) {
      final v = corr[i].abs();
      if (v > bestVal) {
        bestVal = v;
        best = i;
      }
    }
    // Typical level: mean |corr| (robust enough; a median would need a sort).
    var sum = 0.0;
    final count = recording.length - template.length + 1;
    for (var i = 0; i < count; i++) {
      sum += corr[i].abs();
    }
    final mean = sum / count;
    if (mean == 0 || bestVal / mean < minProminence) return null;
    return best;
  }

  /// The nudge (ms) this device needs: how much later it sounds than the
  /// host. [heardA]/[heardB] are sample indexes in the mic recording at
  /// [sampleRate]; [expectedGapMs] is when B was reported audible minus when
  /// A was meant to be audible, both on this device's clock.
  static int nudgeMs({
    required int heardA,
    required int heardB,
    required int sampleRate,
    required double expectedGapMs,
  }) {
    final heardGapMs = (heardB - heardA) * 1000 / sampleRate;
    return (heardGapMs - expectedGapMs).round();
  }

  /// Median of several runs (outliers from a cough or a door slam).
  static int median(List<int> values) {
    final s = [...values]..sort();
    return s[s.length ~/ 2];
  }

  /// corr[i] = Σ_j rec[i + j] · tpl[j], via FFT.
  static Float64List _crossCorrelate(Float32List rec, Float32List tpl) {
    var size = 1;
    while (size < rec.length + tpl.length) {
      size <<= 1;
    }
    final ar = Float64List(size), ai = Float64List(size);
    final br = Float64List(size), bi = Float64List(size);
    for (var i = 0; i < rec.length; i++) {
      ar[i] = rec[i];
    }
    for (var i = 0; i < tpl.length; i++) {
      br[i] = tpl[i];
    }
    _fft(ar, ai, false);
    _fft(br, bi, false);
    // A · conj(B)
    for (var i = 0; i < size; i++) {
      final re = ar[i] * br[i] + ai[i] * bi[i];
      final im = ai[i] * br[i] - ar[i] * bi[i];
      ar[i] = re;
      ai[i] = im;
    }
    _fft(ar, ai, true);
    return ar;
  }

  /// In-place iterative radix-2 FFT (size a power of two).
  static void _fft(Float64List re, Float64List im, bool inverse) {
    final n = re.length;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = 2 * math.pi / len * (inverse ? 1 : -1);
      final wr = math.cos(ang), wi = math.sin(ang);
      for (var i = 0; i < n; i += len) {
        var cr = 1.0, ci = 0.0;
        final half = len >> 1;
        for (var k = 0; k < half; k++) {
          final ur = re[i + k], ui = im[i + k];
          final xr = re[i + k + half], xi = im[i + k + half];
          final vr = xr * cr - xi * ci, vi = xr * ci + xi * cr;
          re[i + k] = ur + vr;
          im[i + k] = ui + vi;
          re[i + k + half] = ur - vr;
          im[i + k + half] = ui - vi;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
    if (inverse) {
      for (var i = 0; i < n; i++) {
        re[i] /= n;
        im[i] /= n;
      }
    }
  }
}

/// Why a mic calibration failed, in words for the user.
class CalibrationException implements Exception {
  const CalibrationException(this.message);

  final String message;

  @override
  String toString() => message;
}
