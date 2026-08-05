import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/models/device_info.dart';
import '../../core/permissions/app_permissions.dart';
import '../../core/session/host_session_controller.dart';
import '../../utils/id_generator.dart';

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
  bool isPickingFile = false;
  String? errorMessage;

  Future<void> startSession(String sessionName) async {
    isStarting = true;
    errorMessage = null;
    notifyListeners();
    try {
      final hasAudioAccess = await AppPermissions.requestAudioLibraryAccess();
      await AppPermissions.requestLocalNetworkAccess();
      if (!hasAudioAccess) {
        errorMessage = 'Audio library access is required to pick a song.';
        return;
      }
      await hostController.start(sessionName);
    } catch (e) {
      errorMessage = 'Failed to start session: $e';
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
      final result = await FilePicker.pickFiles(type: FileType.audio);
      final picked = result?.files.single;
      final path = picked?.path;
      if (path == null) return;
      await hostController.loadTrack(File(path), fileName: picked!.name);
    } catch (e) {
      errorMessage = 'Failed to load track: $e';
    } finally {
      isPickingFile = false;
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
