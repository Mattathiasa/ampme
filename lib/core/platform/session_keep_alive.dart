import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../observability/reporting.dart';

/// Keeps a session running with the screen off (Android): a foreground
/// service with a notification, holding a wakelock and a Wi-Fi lock so audio
/// and the sync loop don't stall when the phone locks. No-op elsewhere.
class SessionKeepAlive {
  SessionKeepAlive._();

  static const _channel = MethodChannel('com.ampme/session');
  static VoidCallback? _onLeave;
  static bool _active = false;

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Shows the session notification. [onLeave] adds a Leave action to it.
  static Future<void> start({
    required String title,
    required String text,
    VoidCallback? onLeave,
  }) async {
    if (!_supported) return;
    _onLeave = onLeave;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'leave') _onLeave?.call();
    });
    try {
      _active = await _channel.invokeMethod<bool>('start', {
            'title': title,
            'text': text,
            'canLeave': onLeave != null,
          }) ??
          false;
    } catch (e, st) {
      reportError(e, st, context: 'SessionKeepAlive.start');
    }
  }

  static Future<void> stop() async {
    _onLeave = null;
    if (!_supported || !_active) return;
    _active = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e, st) {
      reportError(e, st, context: 'SessionKeepAlive.stop');
    }
  }
}
