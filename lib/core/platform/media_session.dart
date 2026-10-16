import '../network/models/track_info.dart';
import 'media_session_stub.dart' if (dart.library.js_interop) 'media_session_web.dart' as impl;

/// Tells the browser what is playing (title, artist, cover), so the lock
/// screen, the notification shade and headset buttons show it. Does nothing
/// outside the browser; a null [track] clears it.
void showNowPlaying(TrackInfo? track, {String? appName}) =>
    impl.showNowPlaying(track, appName: appName);
