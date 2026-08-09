import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../utils/platform_info.dart';

/// Requests the runtime permissions Ampme needs before hosting or joining
/// a session:
/// - audio file access, so the host can pick a local song
///   (`READ_MEDIA_AUDIO` on Android 13+, `READ_EXTERNAL_STORAGE` below it
///   — `permission_handler`'s `Permission.audio` maps to the right one per
///   OS version automatically)
/// - local network access, so discovery/streaming/control sockets work
///   (`NEARBY_WIFI_DEVICES` on Android 13+)
///
/// Every request method takes an optional [BuildContext]. When a permission
/// is *permanently* denied (the user ticked "don't ask again"), passing a
/// context shows a dialog explaining why the permission is needed with an
/// "Open Settings" action, then re-checks the permission when the user
/// returns. Without a context the methods return `false` immediately, as
/// before.
class AppPermissions {
  /// Desktop and web have no runtime permission concept for these: file
  /// pickers handle their own access, browsers gate the camera/mic themselves,
  /// and local sockets don't need one. Skipping the (Android-only)
  /// permission_handler call also avoids the MissingPluginException its
  /// Windows/Linux implementations throw for unsupported permission types.
  static bool get _isDesktopOrWeb => isDesktopPlatform() || kIsWeb;

  static Future<bool> requestAudioLibraryAccess({BuildContext? context}) async {
    if (_isDesktopOrWeb) return true;
    var status = await Permission.audio.request();
    if (status.isPermanentlyDenied && context != null) {
      if (!context.mounted) return false;
      final opened = await _showPermissionSettingsDialog(
        context,
        title: 'Audio library access is needed',
        message:
            'Ampme reads the song from your device so it can stream it to '
            'everyone in the session. Please allow audio access in Settings.',
      );
      if (!opened) return false;
      status = await Permission.audio.status;
    }
    return status.isGranted;
  }

  static Future<bool> requestLocalNetworkAccess() async {
    if (_isDesktopOrWeb) return true;
    final status = await Permission.nearbyWifiDevices.request();
    // Older Android versions don't have this permission at all, in which
    // case permission_handler reports it as unavailable rather than
    // denied — local sockets work regardless, so treat that as success.
    return status.isGranted || status.isLimited;
  }

  /// Camera access, so a listener can scan the host's join QR code.
  static Future<bool> requestCameraAccess({BuildContext? context}) async {
    // No camera API on desktop/web; the QR button is hidden there anyway.
    if (_isDesktopOrWeb) return false;
    var status = await Permission.camera.request();
    if (status.isPermanentlyDenied && context != null) {
      if (!context.mounted) return false;
      final opened = await _showPermissionSettingsDialog(
        context,
        title: 'Camera access is needed',
        message:
            'Ampme uses the camera to scan the QR code shown on the host '
            'device. Please allow camera access in Settings.',
      );
      if (!opened) return false;
      status = await Permission.camera.status;
    }
    return status.isGranted;
  }

  /// Microphone access, so a host can capture and broadcast live audio
  /// ("amplify the room", or device-audio capture, which also requires
  /// `RECORD_AUDIO` at the native layer). [title]/[message] let callers
  /// explain *why* the permission is needed for their specific flow when the
  /// generic microphone copy doesn't fit.
  static Future<bool> requestMicrophoneAccess({
    BuildContext? context,
    String? title,
    String? message,
  }) async {
    // The recorder plugin (record_windows) surfaces its own mic errors, and
    // browsers gate the mic themselves — nothing to gate here.
    if (_isDesktopOrWeb) return true;
    var status = await Permission.microphone.request();
    if (status.isPermanentlyDenied && context != null) {
      if (!context.mounted) return false;
      final opened = await _showPermissionSettingsDialog(
        context,
        title: title ?? 'Microphone access is needed',
        message:
            message ??
            'Ampme captures your microphone to broadcast the room live to '
                'everyone in the session. Please allow microphone access in '
                'Settings.',
      );
      if (!opened) return false;
      status = await Permission.microphone.status;
    }
    return status.isGranted;
  }

  /// Notification access (Android 13+), so the media playback notification
  /// from just_audio_background is actually visible. Older Android versions
  /// don't have this permission; permission_handler reports it as
  /// unavailable there, so treat that as success.
  static Future<bool> requestNotificationAccess() async {
    if (_isDesktopOrWeb) return true;
    final status = await Permission.notification.request();
    return status.isGranted || status.isLimited;
  }

  /// Explains a permanently-denied permission and offers to open the app's
  /// Settings page. Returns true only if the user actually went to Settings
  /// (so the caller knows to re-check the permission afterwards).
  static Future<bool> _showPermissionSettingsDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) async {
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (openSettings != true) return false;
    return openAppSettings();
  }
}
