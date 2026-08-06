import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Scaffold for capturing **other apps'** audio output (e.g. Spotify) and
/// broadcasting it, as an alternative to the microphone-based
/// `LiveMicBroadcaster` ("amplify the room") that ships today.
///
/// This is intentionally a thin, not-yet-wired seam. The real capture path
/// is Android-only and non-trivial:
///
/// 1. Request `MediaProjection` (the system screen/audio-capture consent
///    dialog) once per session — API 29+ only.
/// 2. Build an `AudioRecord` with an
///    `AudioPlaybackCaptureConfiguration` targeting `USAGE_MEDIA` /
///    `USAGE_GAME`, running inside a `mediaProjection`-typed foreground
///    service.
/// 3. Stream the captured 16-bit PCM back over a `MethodChannel`/`EventChannel`
///    into [AudioHttpServer.setLiveSource], exactly like the mic path.
///
/// Hard limits to keep in mind when implementing:
/// - iOS/web cannot do this at all — it must stay behind [isSupported].
/// - Apps that set `android:allowAudioPlaybackCapture="false"` (Spotify and
///   others) are silently excluded by the OS; the user hears nothing.
///
/// Until the native side lands, [isSupported] resolves `false` and
/// [start] throws, so callers can offer the mic broadcast as the working
/// option.
class SystemAudioCapture {
  static const MethodChannel _channel = MethodChannel('com.ampme/system_audio_capture');

  /// Whether the current platform+OS can capture other apps' audio. Today
  /// this is always `false` (native side not implemented); wire it to the
  /// Kotlin handler once that exists.
  Future<bool> isSupported() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      return supported ?? false;
    } on MissingPluginException {
      // Native handler not registered yet.
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Begins capture, returning a live 16-bit PCM stream to feed the HTTP
  /// server. Throws until the native implementation exists.
  Future<Stream<Uint8List>> start() {
    throw UnsupportedError(
      'System-audio capture is not implemented yet. Use LiveMicBroadcaster '
      '("amplify the room") for now.',
    );
  }

  Future<void> stop() => _channel.invokeMethod<void>('stop');
}
