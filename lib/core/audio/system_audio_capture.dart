import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Captures the host device's **system audio** — whatever other apps are
/// playing (Spotify, YouTube, a game) — as a live 16-bit PCM stream so it can
/// be re-served to listeners, exactly like `LiveMicBroadcaster` does for the
/// microphone ("broadcast device audio").
///
/// Backed by Android's `MediaProjection` + `AudioPlaybackCapture` APIs: the
/// system shows a consent dialog per session, a foreground service
/// ([SystemAudioCaptureService]) records the mix and streams the PCM over an
/// `EventChannel` into [pcmStream].
///
/// Platform limits:
/// - Android 10+ only — [isSupported] is `false` everywhere else (iOS/web
///   have no API for capturing other apps' audio; Windows would need a
///   separate WASAPI loopback implementation).
/// - Apps that set `android:allowAudioPlaybackCapture="false"` (Spotify among
///   others) are silently excluded by the OS, and DRM-protected content can't
///   be captured at all.
class SystemAudioCapture {
  static const MethodChannel _channel = MethodChannel(
    'com.ampme/system_audio_capture',
  );
  static const EventChannel _events = EventChannel(
    'com.ampme/system_audio_capture/events',
  );

  static const int sampleRate = 44100;
  static const int channels = 2;
  static const int bitsPerSample = 16;

  StreamController<Uint8List>? _controller;
  StreamSubscription<dynamic>? _eventSub;
  bool _capturing = false;

  /// Invoked when capture ends *outside* Dart's control — the user stopped
  /// the system capture notification, or consent was revoked — so the owner
  /// can tear down its broadcast state. Not called for explicit [stop] calls
  /// (the caller handles those itself).
  Future<void> Function()? onStopped;

  bool get isCapturing => _capturing;

  /// The live PCM feed. Valid only while [isCapturing]; each HTTP response
  /// listens to it independently.
  Stream<Uint8List> get pcmStream =>
      _controller?.stream ?? const Stream.empty();

  /// Whether the current platform can capture other apps' audio. On Android
  /// this resolves the native-side SDK check (10+); everywhere else it's
  /// `false` without touching any platform channels.
  Future<bool> isSupported() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      return supported ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Begins capturing device audio. Shows the system consent dialog; throws a
  /// [PlatformException] (code `CAPTURE_DENIED`) if the user denies it.
  Future<void> start() async {
    if (_capturing) return;

    // Listen before invoking `start` so no PCM emitted right after consent is
    // lost while the broadcast is armed.
    final controller = StreamController<Uint8List>.broadcast();
    _controller = controller;
    _eventSub = _events.receiveBroadcastStream().listen(
      (chunk) {
        if (chunk is Uint8List && !controller.isClosed) controller.add(chunk);
      },
      onError: (Object e, StackTrace st) {
        if (!controller.isClosed) controller.addError(e, st);
      },
      onDone: () {
        // Native side ended the stream (system stopped the capture): reset
        // state and let the owner react.
        _reset();
        final callback = onStopped;
        if (callback != null) unawaited(callback());
      },
      cancelOnError: false,
    );

    try {
      // The timeout guards against the activity being destroyed while the
      // consent dialog is open (the pending result would otherwise be lost
      // and this future would never complete).
      await _channel.invokeMethod<void>('start').timeout(
        const Duration(seconds: 45),
      );
    } catch (_) {
      // Denied, timed out, or channel unavailable: unwind the listener and
      // best-effort stop anything the native side may have started.
      await _eventSub?.cancel();
      _eventSub = null;
      await controller.close();
      _controller = null;
      try {
        await _channel.invokeMethod<void>('stop');
      } on PlatformException {
        // Ignored — nothing native to stop.
      } on MissingPluginException {
        // Ignored — no native side.
      }
      rethrow;
    }
    _capturing = true;
  }

  /// Ends the capture and closes the stream. Does *not* fire [onStopped] —
  /// the caller already knows it initiated the stop.
  Future<void> stop() async {
    if (!_capturing) return;
    _capturing = false;
    // Cancel the subscription first: the native side won't deliver the
    // end-of-stream to a cancelled listener, so [onStopped] stays untouched.
    await _eventSub?.cancel();
    _eventSub = null;
    await _controller?.close();
    _controller = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Best-effort: capture state is already torn down above.
    } on MissingPluginException {
      // Never started natively (unsupported platform).
    }
  }

  Future<void> dispose() async {
    onStopped = null;
    await stop();
  }

  void _reset() {
    _capturing = false;
    _eventSub?.cancel();
    _eventSub = null;
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.close();
    }
    _controller = null;
  }
}
