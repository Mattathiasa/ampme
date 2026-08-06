import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'core/audio/background_audio.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Foreground service + lock-screen controls so playback (and therefore
  // sync) survives the screen turning off. Native only — the browser has no
  // background media service. Guarded so a failure or hang here can never
  // block runApp(): the app must always show its UI, even if background audio
  // is unavailable.
  if (!kIsWeb) {
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'com.ampme.playback',
        androidNotificationChannelName: 'Ampme Playback',
        androidNotificationOngoing: true,
      ).timeout(const Duration(seconds: 5));
      // Only now is it safe to tag audio sources with a MediaItem; see
      // background_audio.dart for why tagging before this throws.
      backgroundAudioReady = true;
    } catch (e, st) {
      debugPrint('JustAudioBackground.init failed (continuing without it): $e\n$st');
    }
  }

  runApp(const AmpmeApp());
}
