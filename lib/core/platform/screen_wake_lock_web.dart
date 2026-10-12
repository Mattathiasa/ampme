import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

web.WakeLockSentinel? _sentinel;
JSFunction? _onVisible;
bool _wanted = false;

Future<bool> acquireScreenWakeLock() async {
  if (!web.window.navigator.has('wakeLock')) return false;
  _wanted = true;
  // The browser drops the lock whenever the tab is hidden: take it again
  // when the tab comes back.
  _onVisible ??= ((web.Event _) {
    if (_wanted && web.document.visibilityState == 'visible') _request();
  }).toJS;
  web.document.addEventListener('visibilitychange', _onVisible);
  return _request();
}

Future<bool> _request() async {
  try {
    _sentinel = await web.window.navigator.wakeLock.request('screen').toDart;
    return true;
  } catch (_) {
    return false; // e.g. battery saver, or not allowed in this frame
  }
}

void releaseScreenWakeLock() {
  _wanted = false;
  final onVisible = _onVisible;
  if (onVisible != null) web.document.removeEventListener('visibilitychange', onVisible);
  final sentinel = _sentinel;
  _sentinel = null;
  if (sentinel != null) sentinel.release().toDart.ignore();
}
