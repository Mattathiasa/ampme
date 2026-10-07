/// Conditional export seam for playing a remote WebRTC audio track.
///
/// Native `flutter_webrtc` plays remote audio tracks automatically; the
/// browser does not — a remote `MediaStream` is silent until it is attached
/// to a media element. On web this resolves to [remote_audio_sink_web.dart]
/// (an `<audio>` element per session); natively to a thin volume wrapper.
library;

export 'remote_audio_sink_native.dart'
    if (dart.library.js_interop) 'remote_audio_sink_web.dart';
