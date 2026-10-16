import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../observability/reporting.dart';
import 'screen_wake_lock.dart';

/// Keeps a session running when the device would otherwise sleep.
///
/// Android: a foreground service with a notification, holding a wakelock
/// and a Wi-Fi lock, so audio and the sync loop carry on with the screen
/// off. Browser: a screen wake lock (a hidden or sleeping tab gets throttled,
/// so the screen has to stay on); [screenMayDim] says when that isn't
/// available, so the page can ask people to keep it open.
class SessionKeepAlive {
  SessionKeepAlive._();

  static const _channel = MethodChannel('com.ampme/session');
  static VoidCallback? _onLeave;

  /// Whether a session wants the service running right now. [start] takes a
  /// moment (a native call); a [stop] that lands meanwhile must win.
  static bool _wanted = false;

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True in a browser that couldn't keep the screen on.
  static bool screenMayDim = false;

  /// Shows the session notification. [onLeave] adds a Leave action to it.
  static Future<void> start({
    required String title,
    required String text,
    VoidCallback? onLeave,
  }) async {
    if (kIsWeb) {
      screenMayDim = !await acquireScreenWakeLock();
      return;
    }
    if (!_supported) return;
    _wanted = true;
    _onLeave = onLeave;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'leave') _onLeave?.call();
    });
    try {
      await _channel.invokeMethod<bool>('start', {
        'title': title,
        'text': text,
        'canLeave': onLeave != null,
      });
      // The session ended while the service was starting: don't leave it
      // running (with its wake lock) for a session that no longer exists.
      if (!_wanted) await _channel.invokeMethod<void>('stop');
    } catch (e, st) {
      reportError(e, st, context: 'SessionKeepAlive.start');
    }
  }

  static Future<void> stop() async {
    _onLeave = null;
    _wanted = false;
    if (kIsWeb) {
      releaseScreenWakeLock();
      screenMayDim = false;
      return;
    }
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e, st) {
      reportError(e, st, context: 'SessionKeepAlive.stop');
    }
  }
}
