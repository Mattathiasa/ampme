import 'dart:async';
import 'dart:typed_data';

import '../audio/audio_engine.dart';
import '../audio/bytes_uri.dart';
import '../audio/wav_writer.dart';
import '../observability/reporting.dart';
import 'acoustic_calibration.dart';

/// Plays one calibration chirp through [engine] — on a listener, the very
/// player the music uses, so the chirp carries exactly the music's output
/// delay.
///
/// The WAV is [leadMs] of silence, the chirp, then a tail; the player starts
/// [leadMs] early so the chirp itself lands on the requested instant. The
/// lead is long on purpose: right after a start, Android players report a
/// rough position (no output timestamps yet), so the chirp's timing is read
/// only once the player is well into steady state ([measuredChirpTime]).
class ChirpPlayer {
  ChirpPlayer(this._engine);

  static const int sampleRate = 48000;
  static const int leadMs = 1200;
  static const int tailMs = 1000;

  final AudioEngine _engine;

  static Uint8List _wav({required bool host}) {
    final chirp = AcousticCalibration.chirp(sampleRate, up: host);
    final lead = sampleRate * leadMs ~/ 1000;
    final pcm = Float32List(lead + chirp.length + sampleRate * tailMs ~/ 1000)
      ..setRange(lead, lead + chirp.length, chirp);
    return wavFromPcm([pcm], sampleRate);
  }

  /// Schedules the chirp to sound at [at] (this device's clock).
  Future<void> playAt(DateTime at, {required bool host}) async {
    final uri = await bytesToUri(
      _wav(host: host),
      name: host ? 'chirp-a.wav' : 'chirp-b.wav',
      mime: 'audio/wav',
    );
    await _engine.loadUrl(uri, title: 'Calibration');
    await _engine.scheduleStart(at: at.subtract(const Duration(milliseconds: leadMs)));
  }

  /// How far ahead hosts schedule their chirp: the listener starts its own
  /// player [leadMs] before its chirp, so it needs that much notice and more.
  static const Duration hostChirpDelay = Duration(milliseconds: 2000);

  /// Host side of a calibration: schedules chirp A [delay] from now. Returns
  /// the planned instant (ms since epoch, this device's clock) to send right
  /// away, and when it actually sounded per the player (null if it never
  /// played) — a player can't start on an exact instant, so the listener
  /// should prefer the latter. Failures are reported, never thrown.
  ({int plannedMs, Future<int?> actualMs}) startHostChirp({Duration delay = hostChirpDelay}) {
    final at = DateTime.now().add(delay);
    final actual = playAt(at, host: true).then((_) async {
      // Read it in steady state, after the chirp.
      final readAt = at.add(const Duration(milliseconds: 300));
      final wait = readAt.difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      return (await measuredChirpTime())?.millisecondsSinceEpoch;
    }).catchError((Object e, StackTrace st) {
      reportError(e, st, context: 'host calibration chirp');
      return null;
    });
    return (plannedMs: at.millisecondsSinceEpoch, actualMs: actual);
  }

  /// When the chirp's first sample was audible per the player, from the
  /// median of several position readings (call while it's still playing,
  /// well after its start). Null if it isn't playing.
  Future<DateTime?> measuredChirpTime({
    int samples = 5,
    Duration every = const Duration(milliseconds: 60),
  }) async {
    final times = <int>[];
    for (var i = 0; i < samples; i++) {
      if (i > 0) await Future<void>.delayed(every);
      final t = reportedChirpTime(DateTime.now());
      if (t != null) times.add(t.microsecondsSinceEpoch);
    }
    if (times.isEmpty) return null;
    times.sort();
    return DateTime.fromMicrosecondsSinceEpoch(times[times.length ~/ 2]);
  }

  /// When the player says the chirp's first sample was audible, judged from
  /// its position right [now]; null if it isn't playing yet.
  DateTime? reportedChirpTime(DateTime now) {
    final pos = _engine.estimatePositionAt(now).inMilliseconds;
    if (pos <= 0) return null;
    return now.subtract(Duration(milliseconds: pos - leadMs));
  }
}
