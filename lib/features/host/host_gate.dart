/// Conditional export seam for the host screen.
///
/// Hosting a session runs an HTTP audio server, a WebSocket control server
/// and a UDP discovery beacon — all built on `dart:io`, which the browser
/// doesn't provide. On web this resolves to [host_screen_web.dart], which
/// hosts differently: it plays the picked file with WebAudio and streams it
/// to listeners over WebRTC (signaled through Supabase Realtime, or the LAN
/// relay). On native it resolves to the real [HostScreen].
library;

export 'host_screen.dart' if (dart.library.js_interop) 'host_screen_web.dart';
