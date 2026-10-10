import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initSentry();

  runApp(const AmpmeApp());
}

/// Enables Sentry crash reporting when a DSN is provided at build time:
///
/// ```sh
/// flutter run --dart-define=SENTRY_DSN=https://<key>@o<org>.ingest.sentry.io/<project>
/// ```
///
/// Without a DSN the app runs exactly as before (reportError() only logs).
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
    },
  );
}
