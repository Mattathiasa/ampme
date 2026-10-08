import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

bool get pageHasUserActivation {
  try {
    final activation = (web.window.navigator as JSObject).getProperty<JSObject?>(
      'userActivation'.toJS,
    );
    // Browsers without the API (old Safari): assume a tap is needed.
    if (activation == null) return false;
    return activation.getProperty<JSBoolean>('hasBeenActive'.toJS).toDart;
  } catch (_) {
    return false;
  }
}
