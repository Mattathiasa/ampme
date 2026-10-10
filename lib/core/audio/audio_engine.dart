import '../network/models/playback_state.dart';

/// Abstraction over the actual audio player, so playback/scheduling code
/// (used by both host and listener session controllers) doesn't depend on
/// a specific player package. `just_audio` is the only implementation for
/// v1 ([JustAudioEngine]); a future streaming-service source would add
/// another `loadX(...)` method here (or a separate track-resolution layer
/// upstream of it) without touching this interface's playback/scheduling
/// contract.
///
/// Named `AudioEngine` (not `AudioSource`) to avoid colliding with
/// `just_audio`'s own `AudioSource` class, which stays an implementation
/// detail of [JustAudioEngine].
abstract class AudioEngine {
  /// Loads a local file for playback (host role). Returns the track
  /// duration once known. [title] labels the background/lock-screen media
  /// notification.
  Future<Duration?> loadLocalFile(String path, {required String title});

  /// Loads a remote stream for playback (listener role: the host's
  /// `/stream/<trackId>` URL). Returns the track duration once known.
  /// [title] labels the background/lock-screen media notification.
  Future<Duration?> loadUrl(Uri uri, {required String title});

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  /// Seeks to [position] and waits (generously bounded) until the player has
  /// buffered enough to start producing audio immediately. Call after
  /// loading so a follow-up [scheduleStart] can fire exactly on its target
  /// instant instead of waiting on the network mid-command.
  Future<void> prepareForStart(Duration position);

  /// Pre-buffers/seeks to [position] immediately, waits until the player is
  /// actually ready to emit audio, then fires playback so the audible start
  /// lines up with the wall-clock instant [at] as closely as possible. If
  /// [at] has already passed (or buffering ate the whole lead), seeks to
  /// `position + (now - at)` and plays immediately (a "catch-up seek").
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero});

  /// The player's current playhead position, fresher than any cached UI
  /// state (used for drift measurement between host and listeners).
  ///
  /// Note this is quantized to the platform's position-update grid
  /// (≈250ms on Android), so it is only accurate to within that interval.
  Duration get currentPosition;

  /// Estimated playhead at wall-clock instant [t], extrapolated from the most
  /// recent position update at the player's nominal rate.
  ///
  /// Position updates arrive on a coarse grid, so pairing a raw
  /// [currentPosition] with a fresh wall-clock timestamp yields a reference
  /// that's systematically up to a poll interval "behind" — exactly the kind
  /// of bias that makes drift-correction loops chase themselves. While
  /// playing, this extrapolates smoothly (accurate to a few ms); while paused
  /// it returns the frozen playhead. Prefer it over [currentPosition]
  /// whenever a timestamp-consistent position is needed (host references,
  /// listener drift checks, status reports).
  Duration estimatePositionAt(DateTime t);

  Future<void> setVolume(double volume);

  /// Playback rate (1.0 = normal), pitch preserved. Listeners trim small
  /// drift with a rate a few percent off 1.0 instead of seeking.
  Future<void> setSpeed(double speed);

  Stream<Duration> get positionStream;

  Stream<PlaybackState> get stateStream;

  Duration? get duration;

  Future<void> dispose();
}
