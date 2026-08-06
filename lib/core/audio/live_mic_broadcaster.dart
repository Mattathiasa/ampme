import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Captures the host device's microphone as a raw 16-bit PCM stream so it
/// can be re-served to listeners as a live "amplify the room" broadcast.
///
/// Exposes the PCM as a **broadcast** stream: the HTTP server opens one
/// response per connected listener and each subscribes to the same live
/// audio. Mono at 44.1 kHz keeps the bandwidth modest while staying
/// music-grade.
class LiveMicBroadcaster {
  LiveMicBroadcaster({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  static const int sampleRate = 44100;
  static const int channels = 1;
  static const int bitsPerSample = 16;

  StreamController<Uint8List>? _controller;
  StreamSubscription<Uint8List>? _micSub;
  bool _broadcasting = false;

  bool get isBroadcasting => _broadcasting;

  /// The live PCM feed. Valid only while [isBroadcasting]; each HTTP
  /// response listens to it independently.
  Stream<Uint8List> get pcmStream =>
      _controller?.stream ?? const Stream.empty();

  /// Begins capturing the microphone. Throws if the mic isn't available or
  /// permission was denied (callers request permission beforehand).
  Future<void> start() async {
    if (_broadcasting) return;

    final micStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
      ),
    );

    final controller = StreamController<Uint8List>.broadcast();
    _controller = controller;
    _micSub = micStream.listen(
      (chunk) {
        if (!controller.isClosed) controller.add(chunk);
      },
      onError: (Object e, StackTrace st) {
        if (!controller.isClosed) controller.addError(e, st);
      },
      cancelOnError: false,
    );
    _broadcasting = true;
  }

  Future<void> stop() async {
    if (!_broadcasting) return;
    _broadcasting = false;
    await _micSub?.cancel();
    _micSub = null;
    await _recorder.stop();
    await _controller?.close();
    _controller = null;
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
