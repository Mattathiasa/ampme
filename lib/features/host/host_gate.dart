/// Conditional export seam for the host screen.
///
/// Hosting a session runs an HTTP audio server, a WebSocket control server
/// and a UDP discovery beacon — all built on `dart:io`, which the browser
/// doesn't provide. On web this resolves to a lightweight "hosting is
/// mobile-only" screen so the app still compiles; on Android/native it
/// resolves to the real [HostScreen].
library;

export 'host_screen.dart'
    if (dart.library.html) 'host_screen_unsupported.dart';
