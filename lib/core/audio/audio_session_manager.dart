import 'dart:async';

import 'package:audio_session/audio_session.dart';

/// Owns the app-wide audio session (Android audio focus / iOS audio session).
///
/// just_audio activates its players on this session; configuring it here for
/// music playback is what lets a phone call, navigation prompt or another
/// media app cleanly take over (and hand back) audio focus.
///
/// Interruption *events* are re-broadcast so session controllers can react in
/// sync-aware ways (e.g. the host telling listeners it paused for a call).
/// The local pause/resume itself is handled by just_audio's built-in
/// interruption handling (AudioPlayer(handleInterruptions: true) is the
/// default), so players pause on interruption begin and resume on end.
class AudioSessionManager {
  AudioSessionManager._();

  static final AudioSessionManager instance = AudioSessionManager._();

  AudioSession? _session;
  bool _configured = false;

  final _interruptionController =
      StreamController<AudioInterruptionEvent>.broadcast();

  /// Interruption begin/end events, forwarded from the platform session.
  Stream<AudioInterruptionEvent> get interruptionEvents =>
      _interruptionController.stream;

  /// Returns the configured [AudioSession], configuring it on first call.
  ///
  /// Safe to call multiple times (every engine/controller shares one session);
  /// reconfiguration is a no-op after the first time.
  Future<AudioSession> ensureConfigured() async {
    final session = _session ??= await AudioSession.instance;
    if (!_configured) {
      _configured = true;
      await session.configure(const AudioSessionConfiguration.music());
      session.interruptionEventStream.listen(_interruptionController.add);
    }
    return session;
  }
}
