/// Describes the track currently loaded in a session, and where listeners
/// can stream its audio bytes from (the host's local HTTP server).
class TrackInfo {
  const TrackInfo({
    required this.trackId,
    required this.fileName,
    required this.streamUrl,
    required this.durationMs,
    this.isLive = false,
    this.hasVideo = false,
    this.liveEpoch,
    this.liveSampleRate,
  });

  final String trackId;
  final String fileName;
  final String streamUrl;
  final int durationMs;

  /// True for a live broadcast (microphone / captured audio): the stream has
  /// no fixed length, can't be seeked, and listeners play it immediately
  /// rather than on a scheduled start.
  final bool isLive;

  /// The host is showing this file's video; listeners play its sound.
  final bool hasVideo;

  /// Set for audio the web host captures live (a shared browser tab): the
  /// capture session's id and its sample rate. The audio arrives over the
  /// `ampme-live` data channel; position 0 is the first captured frame, and
  /// every device plays it at the same delay behind the capture.
  final int? liveEpoch;
  final int? liveSampleRate;

  bool get isLiveCapture => liveEpoch != null && liveSampleRate != null;

  Map<String, dynamic> toJson() => {
    'trackId': trackId,
    'fileName': fileName,
    'streamUrl': streamUrl,
    'durationMs': durationMs,
    'isLive': isLive,
    if (hasVideo) 'hasVideo': true,
    'liveEpoch': ?liveEpoch,
    'liveSampleRate': ?liveSampleRate,
  };

  factory TrackInfo.fromJson(Map<String, dynamic> json) {
    return TrackInfo(
      trackId: json['trackId'] as String,
      fileName: json['fileName'] as String,
      streamUrl: json['streamUrl'] as String,
      durationMs: json['durationMs'] as int,
      // Tolerate older hosts that don't send the field.
      isLive: json['isLive'] as bool? ?? false,
      hasVideo: json['hasVideo'] as bool? ?? false,
      liveEpoch: json['liveEpoch'] as int?,
      liveSampleRate: json['liveSampleRate'] as int?,
    );
  }
}
