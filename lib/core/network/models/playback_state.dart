/// Playback state shared between host and listener sessions.
enum PlaybackState { stopped, buffering, playing, paused }

extension PlaybackStateJson on PlaybackState {
  String toJsonValue() => name;

  static PlaybackState fromJsonValue(String value) {
    return PlaybackState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => PlaybackState.stopped,
    );
  }
}
