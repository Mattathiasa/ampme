import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'core/audio/background_audio.dart';
import 'core/observability/reporting.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initSentry();

  // Foreground service + lock-screen controls so playback (and therefore
  // sync) survives the screen turning off. Native mobile only — the browser
  // has no background media service, and on Windows playback runs on
  // just_audio_windows (WinRT MediaPlayer), which has no service either.
  //
  // Failure handling matters here. JustAudioBackground.init() swaps
  // JustAudioPlatform.instance for its own plugin *before* it awaits
  // AudioService.init(), and the package's top-level `_audioHandler` is only
  // assigned once that init completes. If init throws or times out (service
  // binding failure, a stale native service from a previous interrupted run,
  // emulator quirks, ...), _audioHandler stays uninitialized but the broken
  // plugin stays registered — every subsequent just_audio call, even with an
  // untagged source, then throws
  // "LateInitializationError: Field '_audioHandler' has not been
  // initialized", which surfaces to users as "Failed to load track".
  //
  // So on any failure we restore the platform we saved before init: playback
  // falls back to plain just_audio (ExoPlayer) with no background service —
  // no lock-screen controls, but audio loads and plays without errors.
  if (!kIsWeb && defaultTargetPlatform != TargetPlatform.windows) {
    final originalPlatform = JustAudioPlatform.instance;
    try {
      // Generous timeout so a hanging init can never block the app from
      // starting; on a healthy device init completes in well under a second.
      await JustAudioBackground.init(
        androidNotificationChannelId: 'com.ampme.playback',
        androidNotificationChannelName: 'Ampme Playback',
        androidNotificationOngoing: true,
      ).timeout(const Duration(seconds: 10));
      // Only now is it safe to tag audio sources with a MediaItem; see
      // background_audio.dart for why tagging before this throws.
      backgroundAudioReady = true;
    } catch (e, st) {
      if (!identical(JustAudioPlatform.instance, originalPlatform)) {
        JustAudioPlatform.instance = originalPlatform;
      }
      reportError(
        e,
        st,
        context: 'JustAudioBackground.init failed — falling back to plain just_audio',
      );
    }
  }

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
