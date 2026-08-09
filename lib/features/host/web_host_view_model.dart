import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';

import '../../core/observability/reporting.dart';
import 'web_host_controller.dart';

/// UI-facing wrapper around [WebHostController] for the web host screen:
/// session start, file picking (bytes on web), and error surfacing.
class WebHostViewModel extends ChangeNotifier {
  WebHostViewModel() : hostController = WebHostController() {
    hostController.addListener(notifyListeners);
  }

  final WebHostController hostController;

  bool isStarting = false;
  bool isPickingFile = false;

  bool get isRunning => hostController.sessionCode.isNotEmpty;

  /// [relayAddress] is optional and defaults to the page's own origin (the
  /// relay that served it).
  Future<void> startSession(
    String sessionName, {
    String? relayAddress,
  }) async {
    isStarting = true;
    notifyListeners();
    try {
      var relayHost = relayAddress;
      var relayPort = 8080;
      if (relayAddress != null && relayAddress.isNotEmpty) {
        final parts = relayAddress.split(':');
        if (parts.length == 2) {
          relayHost = parts[0];
          relayPort = int.tryParse(parts[1]) ?? 8080;
        }
      }
      await hostController.start(sessionName, relayHost: relayHost, relayPort: relayPort);
    } catch (e, st) {
      hostController.errorMessage = 'Failed to start session: $e';
      reportError(e, st, context: 'webHost.startSession');
      hostController.notifyListeners();
    } finally {
      isStarting = false;
      notifyListeners();
    }
  }

  Future<void> pickAndLoadTrack() async {
    isPickingFile = true;
    notifyListeners();
    try {
      final result = await FilePicker.pickFiles(type: FileType.audio);
      final picked = result?.files.single;
      final bytes = picked?.bytes;
      if (bytes == null || picked == null) return;
      await hostController.loadTrack(bytes, picked.name);
    } catch (e, st) {
      hostController.errorMessage = 'Failed to load track: $e';
      reportError(e, st, context: 'webHost.pickTrack');
      hostController.notifyListeners();
    } finally {
      isPickingFile = false;
      notifyListeners();
    }
  }

  Future<void> play() => hostController.play();
  Future<void> pause() => hostController.pause();
  Future<void> seek(Duration position) => hostController.seek(position);
  Future<void> setVolume(double volume) => hostController.setVolume(volume);
  Future<void> end() => hostController.end();

  @override
  void dispose() {
    hostController.removeListener(notifyListeners);
    hostController.dispose();
    super.dispose();
  }
}
