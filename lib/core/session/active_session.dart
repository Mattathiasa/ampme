import 'package:flutter/foundation.dart';

import '../network/models/playback_state.dart';
import '../network/models/track_info.dart';

/// The common surface a joined session exposes to the join UI, regardless of
/// the underlying transport.
///
/// [ListenerSessionController] (a native host over WebSocket + HTTP) and
/// [WebRtcListenerController] (a browser-hosted session over WebRTC) both
/// implement this, so `JoinScreen`/`JoinViewModel` can treat either the same
/// way.
abstract class ActiveSession extends ChangeNotifier {
  /// The host's session name, once known.
  String? get sessionName;

  /// True for a stream with no seekable position (live mic broadcast). The
  /// UI shows the live view in that case.
  bool get isLiveSession;

  /// The track currently being streamed. Null until the session reports one.
  TrackInfo? get currentTrack;

  PlaybackState get playbackState;

  /// Current playhead position. For live sessions this advances in real time
  /// and isn't meaningful for seeking.
  Duration get position;

  /// This device's own output volume (0..1).
  double get volume;

  /// Set once the host ends the session or the connection drops.
  bool get hostLeft;

  /// The host took this device out of the session (so [hostLeft] is true
  /// too, but the session is still running for everyone else).
  bool get removedByHost;

  /// True while the control connection is being re-established.
  bool get isReconnecting;

  /// Why the current song could not be loaded, if it could not (it never
  /// arrived, or this device could not play it). Null while all is well.
  String? get loadProblem;

  /// Tries to load the current song again.
  Future<void> retryLoad();

  /// The host answered but a direct connection never came up (typically
  /// the two devices are on different networks).
  bool get connectProblem;

  /// Host<->local clock offset estimate, once clock sync has run.
  int? get clockOffsetMs;

  /// Round-trip time of the clock-sync exchange, when available.
  int? get roundTripMs;

  /// True when the browser blocked audio autoplay and playback needs a tap
  /// ([unlockAudio]) to start. Always false outside the browser.
  bool get needsAudioUnlock;

  /// Starts audio the browser refused to autoplay. Call from a tap handler.
  Future<void> unlockAudio();

  /// Sets this device's local playback volume without affecting other devices.
  Future<void> setLocalVolume(double value);

  /// How much earlier (ms) this device plays than the shared timeline, to
  /// make up for its own speaker delay. Set by ear or by mic calibration.
  int get syncNudgeMs;

  /// Sets [syncNudgeMs]; takes effect at the next drift check (≤ 1 s).
  void setSyncNudge(int ms);

  /// Measures this device's speaker delay against the host's with the mic
  /// and sets [syncNudgeMs] from it (three runs, median). [onRun] reports
  /// progress (0, 1, 2). Throws `CalibrationException` with a user-facing
  /// reason on failure.
  Future<int> calibrateWithMic({void Function(int run)? onRun});

  /// The individual readings (ms late) of the last successful calibration.
  List<int> get lastCalibrationRuns;

  /// Fraction (0..1) of the current song still being copied to this device
  /// (browser-hosted sessions send the file before playing); null otherwise.
  double? get trackDownloadProgress;
}
