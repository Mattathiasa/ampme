import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'core/observability/diagnostics.dart';
import 'core/observability/sentry_scrub.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initSentry();
  _recordUncaughtErrors();

  runApp(const AmpmeApp());
}

/// Whatever escapes the app's own error handling still lands in the
/// diagnostics people can copy (and in Sentry, which hooks the same places
/// itself when it is on). The previous handlers keep running.
void _recordUncaughtErrors() {
  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    Diagnostics.error('flutter', details.exception);
    previousFlutter?.call(details);
  };
  final previousPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    Diagnostics.error('uncaught', error);
    if (previousPlatform != null) return previousPlatform(error, stack);
    debugPrint('Uncaught: $error\n$stack');
    return false;
  };
}

/// Enables Sentry crash reporting when a DSN is provided at build time:
///
/// ```sh
/// flutter run --dart-define=SENTRY_DSN=https://<key>@o<org>.ingest.sentry.io/<project>
/// ```
///
/// Without a DSN the app runs exactly as before (reportError() only logs).
/// What is sent is scrubbed first (session codes, IP addresses) and carries
/// no personal data: no user, no screenshots.
Future<void> _initSentry() async {
  const dsn = String.fromEnvironment('SENTRY_DSN');
  if (dsn.isEmpty) {
    debugPrint('SENTRY_DSN not set — crash reporting disabled.');
    return;
  }
  await SentryFlutter.init(
    (options) {
      options.dsn = dsn;
      options.environment = const String.fromEnvironment(
        'SENTRY_ENVIRONMENT',
        defaultValue: 'production',
      );
      options.sendDefaultPii = false;
      options.beforeSend = (event, hint) => scrubEvent(event);
      options.beforeBreadcrumb = (crumb, hint) => crumb == null ? null : scrubBreadcrumb(crumb);
    },
  );
}
