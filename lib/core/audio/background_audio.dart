/// Tracks whether `just_audio_background` finished initializing.
///
/// `JustAudioBackground.init()` (called from `main`) is best-effort: it swaps
/// `JustAudioPlatform.instance` for its own plugin before `AudioService.init()`
/// completes, and only assigns its internal `_audioHandler` once that completes.
/// If init throws or times out, `_audioHandler` is never set and *every*
/// subsequent `setAudioSource` throws a
/// `LateInitializationError: Field '_audioHandler...' has not been
/// initialized` — which surfaced to users as "Failed to load track".
///
/// `main` guards against that by restoring the original platform on failure,
/// after which all playback runs on plain `just_audio`. When init *succeeds*
/// this flag is `true`, and playback code tags sources with a `MediaItem` so
/// the lock-screen/notification controls work; otherwise sources stay untagged
/// (no lock-screen controls, but audio still plays).
bool backgroundAudioReady = false;
