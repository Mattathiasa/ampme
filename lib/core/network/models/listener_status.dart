import 'playback_state.dart';

/// A listener's periodic self-report to the host, used to render the
/// "connected devices + sync status" list on the host screen.
class ListenerStatus {
  const ListenerStatus({
    required this.deviceId,
    required this.deviceName,
    required this.playbackState,
    required this.positionMs,
    required this.syncOffsetMs,
    required this.roundTripMs,
  });

  final String deviceId;
  final String deviceName;
  final PlaybackState playbackState;
  final int positionMs;
  final int syncOffsetMs;
  final int roundTripMs;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'playbackState': playbackState.toJsonValue(),
    'positionMs': positionMs,
    'syncOffsetMs': syncOffsetMs,
    'roundTripMs': roundTripMs,
  };

  factory ListenerStatus.fromJson(Map<String, dynamic> json) {
    return ListenerStatus(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      playbackState: PlaybackStateJson.fromJsonValue(
        json['playbackState'] as String,
      ),
      positionMs: json['positionMs'] as int,
      syncOffsetMs: json['syncOffsetMs'] as int,
      roundTripMs: json['roundTripMs'] as int,
    );
  }
}
