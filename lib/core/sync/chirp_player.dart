import 'dart:async';
import 'dart:typed_data';

import '../audio/audio_engine.dart';
import '../audio/bytes_uri.dart';
import '../audio/wav_writer.dart';
import 'acoustic_calibration.dart';

/// Plays one calibration chirp through [engine] — on a listener, the very
/// player the music uses, so the chirp carries exactly the music's output
/// delay.
///
/// The WAV is [leadMs] of silence, the chirp, then a tail; the player starts
/// [leadMs] early so the chirp itself lands on the requested instant.
class ChirpPlayer {
  ChirpPlayer(this._engine);

  static const int sampleRate = 48000;
  static const int leadMs = 300;

  final AudioEngine _engine;

  static Uint8List _wav({required bool host}) {
    final chirp = AcousticCalibration.chirp(sampleRate, up: host);
    final lead = sampleRate * leadMs ~/ 1000;
    final pcm = Float32List(lead + chirp.length + sampleRate * 3 ~/ 10)
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

  /// When the player says the chirp's first sample was audible, judged from
  /// its position right [now]; null if it isn't playing yet.
  DateTime? reportedChirpTime(DateTime now) {
    final pos = _engine.estimatePositionAt(now).inMilliseconds;
    if (pos <= 0) return null;
    return now.subtract(Duration(milliseconds: pos - leadMs));
  }
}
