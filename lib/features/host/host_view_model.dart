import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';

import '../../core/network/models/device_info.dart';
import '../../core/observability/reporting.dart';
import '../../core/permissions/app_permissions.dart';
import '../../core/session/host_session_controller.dart';
import '../../utils/id_generator.dart';
import '../../core/media/video_audio_extractor.dart';
import 'sync_math.dart';

/// Wraps [HostSessionController] with the UI-facing concerns a
/// `HostScreen` needs: permission requests, file picking, and surfacing
/// errors — kept separate from the controller so the controller stays
/// Flutter-widget-free and independently testable.
class HostViewModel extends ChangeNotifier {
  HostViewModel()
    : hostController = HostSessionController(
        hostDevice: DeviceInfo(
          deviceId: generateId(),
          deviceName: 'Host-${generateId().substring(0, 4)}',
          platform: Platform.operatingSystem,
        ),
      ) {
    hostController.addListener(notifyListeners);
  }

  final HostSessionController hostController;

  bool isStarting = false;
  /// True while a picked video's sound track is being extracted.
  bool isPreparingVideo = false;
  bool isPickingFile = false;
  bool isTogglingLive = false;
  bool isTogglingSystemAudio = false;
  String? errorMessage;

  /// Whether the "Broadcast device audio" control should be shown (resolved
  /// when the session starts; `false` on platforms that can't capture other
  /// apps' audio).
  bool systemAudioSupported = false;

  bool get isLiveBroadcasting => hostController.isLiveBroadcasting;
  bool get isSystemAudioBroadcasting => hostController.isSystemAudioBroadcasting;

  /// [context] is used to recover from a permanently-denied audio permission
  /// (explain + open Settings); pass the screen's context when available.
  Future<void> startSession(String sessionName, {BuildContext? context}) async {
    isStarting = true;
    errorMessage = null;
    notifyListeners();
    try {
      final hasAudioAccess = await AppPermissions.requestAudioLibraryAccess(
        context: context,
      );
      await AppPermissions.requestLocalNetworkAccess();
      // Best-effort: lets the system-audio capture notification show on
      // Android 13+. Playback works regardless of the outcome.
      await AppPermissions.requestNotificationAccess();
      if (!hasAudioAccess) {
        errorMessage = 'Audio library access is required to pick a song.';
        return;
      }
      await hostController.start(sessionName);
      systemAudioSupported = await hostController.isSystemAudioSupported();
    } catch (e, st) {
      errorMessage = 'Failed to start session: $e';
      reportError(e, st, context: 'startSession');
    } finally {
      isStarting = false;
      notifyListeners();
    }
  }

  Future<void> pickAndLoadTrack() async {
    isPickingFile = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: pickableExtensions,
      );
      final picked = result?.files.single;
      final path = picked?.path;
      if (path == null) return;
      if (isVideoFile(picked!.name)) {
        // Listeners only play the sound: serve them the sound track alone
        // (much smaller, and no picture for their player to decode).
        isPreparingVideo = true;
        notifyListeners();
        final soundPath = await extractAudioTrack(path);
        isPreparingVideo = false;
        await hostController.loadTrack(
          File(soundPath ?? path),
          fileName: picked.name,
          videoPath: path,
        );
      } else {
        await hostController.loadTrack(File(path), fileName: picked.name);
      }
    } catch (e, st) {
      errorMessage = 'Failed to load track: $e';
      reportError(e, st, context: 'pickAndLoadTrack');
    } finally {
      isPickingFile = false;
      notifyListeners();
    }
  }

  /// Starts/stops the live "broadcast device audio" capture (audio other
  /// apps are playing). [context] is used to recover from a permanently-
  /// denied mic permission (explain + open Settings) — the native capture
  /// path requires `RECORD_AUDIO` regardless of source; pass the screen's
  /// context when available.
  Future<void> toggleSystemAudioBroadcast({BuildContext? context}) async {
    isTogglingSystemAudio = true;
    errorMessage = null;
    notifyListeners();
    try {
      if (hostController.isSystemAudioBroadcasting) {
        await hostController.stopSystemAudioBroadcast();
      } else {
        final granted = await AppPermissions.requestMicrophoneAccess(
          context: context,
          title: 'Audio recording access is needed',
          message:
              'Ampme captures this device\'s audio (what other apps are '
              'playing) to broadcast it live to the session. Android requires '
              'the microphone/audio permission for this. Please allow audio '
              'recording in Settings.',
        );
        if (!granted) {
          errorMessage = 'Audio recording access is required to broadcast device audio.';
          return;
        }
        await hostController.startSystemAudioBroadcast();
      }
    } catch (e, st) {
      errorMessage = 'Device audio broadcast failed: $e';
      reportError(e, st, context: 'toggleSystemAudioBroadcast');
    } finally {
      isTogglingSystemAudio = false;
      notifyListeners();
    }
  }

  /// Starts/stops the live "amplify the room" microphone broadcast.
  /// [context] is used to recover from a permanently-denied mic permission
  /// (explain + open Settings); pass the screen's context when available.
  Future<void> toggleLiveBroadcast({BuildContext? context}) async {
    isTogglingLive = true;
    errorMessage = null;
    notifyListeners();
    try {
      if (hostController.isLiveBroadcasting) {
        await hostController.stopLiveBroadcast();
      } else {
        final granted = await AppPermissions.requestMicrophoneAccess(
          context: context,
        );
        if (!granted) {
          errorMessage = 'Microphone access is required to broadcast live audio.';
          return;
        }
        await hostController.startLiveBroadcast();
      }
    } catch (e, st) {
      errorMessage = 'Live broadcast failed: $e';
      reportError(e, st, context: 'toggleLiveBroadcast');
    } finally {
      isTogglingLive = false;
      notifyListeners();
    }
  }

  Future<void> play() => hostController.play();

  Future<void> pause() => hostController.pause();

  Future<void> seek(Duration position) => hostController.seek(position);

  Future<void> setVolume(double volume) => hostController.setVolume(volume);

  @override
  void dispose() {
    hostController.removeListener(notifyListeners);
    hostController.dispose();
    super.dispose();
  }
}
