/// Describes the track currently loaded in a session, and where listeners
/// can stream its audio bytes from (the host's local HTTP server).
class TrackInfo {
  const TrackInfo({
    required this.trackId,
    required this.fileName,
    required this.streamUrl,
    required this.durationMs,
  });

  final String trackId;
  final String fileName;
  final String streamUrl;
  final int durationMs;

  Map<String, dynamic> toJson() => {
    'trackId': trackId,
    'fileName': fileName,
    'streamUrl': streamUrl,
    'durationMs': durationMs,
  };

  factory TrackInfo.fromJson(Map<String, dynamic> json) {
    return TrackInfo(
      trackId: json['trackId'] as String,
      fileName: json['fileName'] as String,
      streamUrl: json['streamUrl'] as String,
      durationMs: json['durationMs'] as int,
    );
  }
}
