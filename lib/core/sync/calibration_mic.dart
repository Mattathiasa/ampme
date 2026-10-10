import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// A short raw microphone recording for calibration (mono, [sampleRate]).
abstract class CalibrationMic {
  static const int sampleRate = 48000;

  Future<void> start();

  /// Stops and returns everything recorded since [start].
  Future<Float32List> stop();
}

/// [CalibrationMic] on the `record` plugin (Android + browsers), with every
/// voice-call processing step off: echo cancellation would erase the very
/// chirp this device plays, and AGC/noise suppression smear timing.
class RecordCalibrationMic implements CalibrationMic {
  final _recorder = AudioRecorder();
  final _chunks = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;

  @override
  Future<void> start() async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: CalibrationMic.sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.unprocessed,
          // Don't switch a Bluetooth headset into call mode mid-party.
          manageBluetooth: false,
        ),
      ),
    );
    _sub = stream.listen(_chunks.add);
  }

  @override
  Future<Float32List> stop() async {
    await _recorder.stop();
    await _sub?.cancel();
    await _recorder.dispose();
    final bytes = _chunks.takeBytes();
    final data = ByteData.sublistView(bytes);
    final out = Float32List(bytes.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    return out;
  }
}
