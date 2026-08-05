/// Identifies a device participating in a session (host or listener).
class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
  });

  final String deviceId;
  final String deviceName;
  final String platform;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
  };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      platform: json['platform'] as String,
    );
  }
}
