import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Reports an error to Sentry when a `SENTRY_DSN` was provided at build time,
/// and always logs it locally (with a short [context] describing what was
/// happening) so debug builds still surface it.
///
/// All uncaught-by-design errors in the app should go through here instead of
/// a bare `debugPrint`, so production crashes are visible in Sentry.
void reportError(Object error, StackTrace? stack, {String? context}) {
  final prefix = context == null ? '' : '$context: ';
  debugPrint('$prefix$error\n$stack');
  if (!Sentry.isEnabled) return;
  Sentry.captureException(error, stackTrace: stack);
}
