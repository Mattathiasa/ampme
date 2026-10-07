import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Native: the platform WebRTC stack already routes remote audio to the
/// speaker, so this only exposes per-device volume.
class RemoteAudioSink {
  RemoteAudioSink({required void Function() onBlocked});

  rtc.MediaStreamTrack? _track;
  double _volume = 1.0;

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
