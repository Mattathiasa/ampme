import 'package:permission_handler/permission_handler.dart';

/// Requests the runtime permissions Ampme needs before hosting or joining
/// a session:
/// - audio file access, so the host can pick a local song
///   (`READ_MEDIA_AUDIO` on Android 13+, `READ_EXTERNAL_STORAGE` below it
///   — `permission_handler`'s `Permission.audio` maps to the right one per
///   OS version automatically)
/// - local network access, so discovery/streaming/control sockets work
///   (`NEARBY_WIFI_DEVICES` on Android 13+)
class AppPermissions {
  static Future<bool> requestAudioLibraryAccess() async {
    final status = await Permission.audio.request();
    return status.isGranted;
  }

  static Future<bool> requestLocalNetworkAccess() async {
    final status = await Permission.nearbyWifiDevices.request();
    // Older Android versions don't have this permission at all, in which
    // case permission_handler reports it as unavailable rather than
    // denied — local sockets work regardless, so treat that as success.
    return status.isGranted || status.isLimited;
  }

  /// Camera access, so a listener can scan the host's join QR code.
  static Future<bool> requestCameraAccess() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  /// Microphone access, so a host can capture and broadcast live audio
  /// ("amplify the room").
  static Future<bool> requestMicrophoneAccess() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }
}
