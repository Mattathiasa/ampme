/// Tracks whether `just_audio_background` finished initializing.
///
/// `JustAudioBackground.init()` (called from `main`) is best-effort and
/// guarded by a timeout: on some devices/emulators — and always on web —
/// it can fail or never complete. When that happens its internal
/// `_audioHandler` field is never set, and attaching a `MediaItem` tag to
/// an audio source makes `setAudioSource` throw a
/// `LateInitializationError: Field '_audioHandler...' has not been
/// initialized`, which surfaced to users as "Failed to load track".
///
/// So playback code must only tag sources with a `MediaItem` when this
/// flag is `true`; otherwise it falls back to an untagged source (no
/// lock-screen controls, but audio still plays).
bool backgroundAudioReady = false;
