import 'dart:convert';

/// Announced periodically by the host over UDP broadcast so listener
/// devices on the same network can discover "nearby sessions" to join.
class SessionBeacon {
  const SessionBeacon({
    required this.sessionName,
    required this.hostDeviceId,
    required this.hostIp,
    required this.controlPort,
    required this.streamPort,
    required this.appVersion,
  });

  final String sessionName;
  final String hostDeviceId;
  final String hostIp;
  final int controlPort;
  final int streamPort;
  final String appVersion;

  Map<String, dynamic> toJson() => {
    'sessionName': sessionName,
    'hostDeviceId': hostDeviceId,
    'hostIp': hostIp,
    'controlPort': controlPort,
    'streamPort': streamPort,
    'appVersion': appVersion,
  };

  String toJsonString() => jsonEncode(toJson());

  factory SessionBeacon.fromJson(Map<String, dynamic> json) {
    return SessionBeacon(
      sessionName: json['sessionName'] as String,
      hostDeviceId: json['hostDeviceId'] as String,
      hostIp: json['hostIp'] as String,
      controlPort: json['controlPort'] as int,
      streamPort: json['streamPort'] as int,
      appVersion: json['appVersion'] as String,
    );
  }

  /// Returns null (rather than throwing) on malformed input, since beacons
  /// arrive from the network and a garbled/foreign packet must not crash
  /// the scanner.
  static SessionBeacon? tryParse(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) return null;
      return SessionBeacon.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}
