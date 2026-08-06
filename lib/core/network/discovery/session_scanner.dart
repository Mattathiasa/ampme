/// Conditional export seam for the UDP session scanner.
///
/// The real scanner ([session_listener_scanner.dart]) uses `dart:io`
/// (`RawDatagramSocket`), which does not exist in the browser. On web this
/// resolves to a no-op stub so the join flow still compiles — web joins a
/// session by code instead of by UDP auto-discovery.
library;

export 'session_listener_scanner.dart'
    if (dart.library.html) 'session_listener_scanner_web.dart';
