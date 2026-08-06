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

  /// Pre-buffers/seeks to [position] immediately, then fires playback so
  /// the audible start lines up with the wall-clock instant [at] as
  /// closely as possible. If [at] has already passed, seeks to
  /// `position + (now - at)` and plays immediately (a "catch-up seek")
  /// instead of just starting from [position].
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero});

  Future<void> setVolume(double volume);

  Stream<Duration> get positionStream;

  Stream<PlaybackState> get stateStream;

  Duration? get duration;

  Future<void> dispose();
}
