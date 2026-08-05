import 'dart:convert';

import 'track_info.dart';

/// All message types exchanged over the host<->listener control WebSocket.
enum ControlMessageType {
  welcome,
  trackChanged,
  play,
  pause,
  seek,
  volume,
  clockSyncRequest,
  clockSyncResponse,
  listenerStatusUpdate;

  String toJsonValue() => name;

  static ControlMessageType fromJsonValue(String value) {
    return ControlMessageType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => throw FormatException('Unknown ControlMessageType: $value'),
    );
  }
}

/// A single JSON message on the control channel:
/// `{ "type": ..., "senderId": ..., "payload": { ... } }`.
///
/// Kept as one class with a raw `payload` map (rather than a sealed
/// hierarchy) so (de)serialization stays simple and dependency-free;
/// the named factory constructors below are the typed construction/read
/// surface callers should use instead of touching `payload` directly.
class ControlMessage {
  const ControlMessage({
    required this.type,
    required this.senderId,
    required this.payload,
  });

  final ControlMessageType type;
  final String senderId;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
    'type': type.toJsonValue(),
    'senderId': senderId,
    'payload': payload,
  };

  String encode() => jsonEncode(toJson());

  factory ControlMessage.fromJson(Map<String, dynamic> json) {
    return ControlMessage(
      type: ControlMessageType.fromJsonValue(json['type'] as String),
      senderId: json['senderId'] as String,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
    );
  }

  /// Throws [FormatException]/[TypeError] on malformed input; callers on
  /// the network boundary (control_server/control_client) are expected to
  /// catch and drop malformed frames rather than propagate.
  factory ControlMessage.decode(String source) {
    return ControlMessage.fromJson(jsonDecode(source) as Map<String, dynamic>);
  }

  // ---- Host -> listener ----

  factory ControlMessage.welcome({
    required String senderId,
    required String sessionId,
    required String sessionName,
    required String hostDeviceId,
    required TrackInfo? currentTrack,
    required String playbackState,
    required int positionMs,
    required int hostTimeMs,
  }) {
    return ControlMessage(
      type: ControlMessageType.welcome,
      senderId: senderId,
      payload: {
        'sessionId': sessionId,
        'sessionName': sessionName,
        'hostDeviceId': hostDeviceId,
        'currentTrack': currentTrack?.toJson(),
        'playbackState': playbackState,
        'positionMs': positionMs,
        'hostTimeMs': hostTimeMs,
      },
    );
  }

  factory ControlMessage.trackChanged({
    required String senderId,
    required TrackInfo track,
  }) {
    return ControlMessage(
      type: ControlMessageType.trackChanged,
      senderId: senderId,
      payload: track.toJson(),
    );
  }

  factory ControlMessage.play({
    required String senderId,
    required String trackId,
    required int positionMs,
    required int startAtHostTimeMs,
  }) {
    return ControlMessage(
      type: ControlMessageType.play,
      senderId: senderId,
      payload: {
        'trackId': trackId,
        'positionMs': positionMs,
        'startAtHostTimeMs': startAtHostTimeMs,
      },
    );
  }

  factory ControlMessage.pause({
    required String senderId,
    required String trackId,
    required int positionMs,
    required int hostTimeMs,
  }) {
    return ControlMessage(
      type: ControlMessageType.pause,
      senderId: senderId,
      payload: {
        'trackId': trackId,
        'positionMs': positionMs,
        'hostTimeMs': hostTimeMs,
      },
    );
  }

  factory ControlMessage.seek({
    required String senderId,
    required String trackId,
    required int positionMs,
    required int startAtHostTimeMs,
  }) {
    return ControlMessage(
      type: ControlMessageType.seek,
      senderId: senderId,
      payload: {
        'trackId': trackId,
        'positionMs': positionMs,
        'startAtHostTimeMs': startAtHostTimeMs,
      },
    );
  }

  factory ControlMessage.volume({
    required String senderId,
    required double volume,
  }) {
    return ControlMessage(
      type: ControlMessageType.volume,
      senderId: senderId,
      payload: {'volume': volume},
    );
  }

  factory ControlMessage.clockSyncResponse({
    required String senderId,
    required int clientSendTimeMs,
    required int hostTimeMs,
  }) {
    return ControlMessage(
      type: ControlMessageType.clockSyncResponse,
      senderId: senderId,
      payload: {'clientSendTimeMs': clientSendTimeMs, 'hostTimeMs': hostTimeMs},
    );
  }

  // ---- Listener -> host ----

  factory ControlMessage.clockSyncRequest({
    required String senderId,
    required int clientSendTimeMs,
  }) {
    return ControlMessage(
      type: ControlMessageType.clockSyncRequest,
      senderId: senderId,
      payload: {'clientSendTimeMs': clientSendTimeMs},
    );
  }

  factory ControlMessage.listenerStatusUpdate({
    required String senderId,
    required String deviceName,
    required String playbackState,
    required int positionMs,
    required int syncOffsetMs,
    required int roundTripMs,
  }) {
    return ControlMessage(
      type: ControlMessageType.listenerStatusUpdate,
      senderId: senderId,
      payload: {
        'deviceName': deviceName,
        'playbackState': playbackState,
        'positionMs': positionMs,
        'syncOffsetMs': syncOffsetMs,
        'roundTripMs': roundTripMs,
      },
    );
  }
}
