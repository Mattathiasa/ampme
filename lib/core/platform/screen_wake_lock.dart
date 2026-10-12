import 'screen_wake_lock_stub.dart' if (dart.library.js_interop) 'screen_wake_lock_web.dart'
    as impl;

/// Keeps the screen on in the browser (Screen Wake Lock API) while a session
/// runs. Returns false where the browser doesn't support it.
Future<bool> acquireScreenWakeLock() => impl.acquireScreenWakeLock();

void releaseScreenWakeLock() => impl.releaseScreenWakeLock();
