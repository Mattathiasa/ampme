/// Describes the track currently loaded in a session, and where listeners
/// can stream its audio bytes from (the host's local HTTP server).
class TrackInfo {
  const TrackInfo({
    required this.trackId,
    required this.fileName,
    required this.streamUrl,
    required this.durationMs,
    this.isLive = false,
  });

  final String trackId;
  final String fileName;
  final String streamUrl;
  final int durationMs;

  /// True for a live broadcast (microphone / captured audio): the stream has
  /// no fixed length, can't be seeked, and listeners play it immediately
  /// rather than on a scheduled start.
  final bool isLive;

  Map<String, dynamic> toJson() => {
    'trackId': trackId,
    'fileName': fileName,
    'streamUrl': streamUrl,
    'durationMs': durationMs,
    'isLive': isLive,
  };

  factory TrackInfo.fromJson(Map<String, dynamic> json) {
    return TrackInfo(
      trackId: json['trackId'] as String,
      fileName: json['fileName'] as String,
      streamUrl: json['streamUrl'] as String,
      durationMs: json['durationMs'] as int,
      // Tolerate older hosts that don't send the field.
      isLive: json['isLive'] as bool? ?? false,
    );
  }
}
