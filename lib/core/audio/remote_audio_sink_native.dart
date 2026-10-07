import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../observability/reporting.dart';

/// Android audio setup for playing *music* received over WebRTC.
///
/// flutter_webrtc's Android defaults are tuned for calls: audio mode
/// `MODE_IN_COMMUNICATION`, voice-call usage (earpiece routing, call volume)
/// and echo cancellation / noise suppression on the playout path — which
/// mangle music. Ampme listeners only receive audio, so use media routing
/// and bypass voice processing (also enables stereo output).
final _musicPlayback = rtc.AndroidAudioConfiguration(
  manageAudioFocus: true,
  androidAudioMode: rtc.AndroidAudioMode.normal,
  androidAudioFocusMode: rtc.AndroidAudioFocusMode.gain,
  androidAudioStreamType: rtc.AndroidAudioStreamType.music,
  androidAudioAttributesUsageType: rtc.AndroidAudioAttributesUsageType.media,
  androidAudioAttributesContentType:
      rtc.AndroidAudioAttributesContentType.music,
);

bool _prepared = false;

/// Native: the platform WebRTC stack already routes remote audio to the
/// speaker, so this only configures the audio path and exposes per-device
/// volume.
class RemoteAudioSink {
  RemoteAudioSink({required void Function() onBlocked});

  rtc.MediaStreamTrack? _track;
  double _volume = 1.0;

  /// Configures the platform audio path for music. Must run before the first
  /// peer connection is created: flutter_webrtc builds its audio device
  /// module once, on its first call, from these options.
  static Future<void> prepare() async {
    if (_prepared) return;
    _prepared = true;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await rtc.WebRTC.initialize(
        options: {
          'androidAudioConfiguration': _musicPlayback.toMap(),
          'bypassVoiceProcessing': true,
        },
      );
      await rtc.Helper.setAndroidAudioConfiguration(_musicPlayback);
    } catch (e, st) {
      // Playback still works with the defaults, just routed like a call.
      reportError(e, st, context: 'remoteAudio.prepare');
    }
  }

  /// Never blocked natively (no autoplay policy).
  bool get isBlocked => false;

  Future<void> attach(rtc.MediaStream stream, rtc.MediaStreamTrack track) async {
    _track = track;
    if (_volume != 1.0) await setVolume(_volume);
  }

  Future<void> setVolume(double volume) async {
    _volume = volume;
    final track = _track;
    if (track == null) return;
    try {
      // flutter_webrtc's gain range is 0..10 with 1.0 as unity.
      await rtc.Helper.setVolume(volume, track);
    } catch (_) {
      // Not supported on every platform; volume stays at system level.
    }
  }

  /// No-op natively; see the web implementation.
  Future<void> resume() async {}

  Future<void> dispose() async {
    _track = null;
  }
}
