/// Conditional export seam for the HTTPS-serving notice.
///
/// The real banner reads `window.location` via `package:web`
/// (`dart:js_interop`), which only compiles on the web platform. Native
/// builds resolve to a no-op stub ([web_serving_notice_native.dart]) so the
/// shared join screen can import this file on every platform; web builds get
/// the actual banner ([web_serving_notice_web.dart]).
library;

export 'web_serving_notice_native.dart'
    if (dart.library.html) 'web_serving_notice_web.dart';
