import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/network/discovery/session_listener_scanner.dart';
import '../../core/network/models/device_info.dart';
import '../../core/permissions/app_permissions.dart';
import '../../core/session/listener_session_controller.dart';
import '../../utils/id_generator.dart';

/// Wraps session discovery (browsing "nearby sessions") and, once the
/// user picks one, the [ListenerSessionController] that actually joins
/// and plays it.
class JoinViewModel extends ChangeNotifier {
  JoinViewModel()
    : selfDevice = DeviceInfo(
        deviceId: generateId(),
        deviceName: 'Listener-${generateId().substring(0, 4)}',
        platform: Platform.operatingSystem,
      );

  final DeviceInfo selfDevice;
  final _scanner = SessionListenerScanner();

  List<DiscoveredSession> nearbySessions = const [];
  ListenerSessionController? session;
  bool isScanning = false;
  bool isConnecting = false;
  String? errorMessage;

  Future<void> startScanning() async {
    if (isScanning) return;
    errorMessage = null;
    await AppPermissions.requestLocalNetworkAccess();
    await _scanner.start();
    isScanning = true;
    _scanner.sessions.listen((sessions) {
      nearbySessions = sessions;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> stopScanning() async {
    await _scanner.stop();
    isScanning = false;
    notifyListeners();
  }

  Future<void> join(DiscoveredSession discovered) async {
    isConnecting = true;
    errorMessage = null;
    notifyListeners();
    try {
      await AppPermissions.requestLocalNetworkAccess();
      await stopScanning();

      final controller = ListenerSessionController(selfDevice: selfDevice);
      controller.addListener(notifyListeners);
      await controller.connect(
        hostIp: discovered.beacon.hostIp,
        controlPort: discovered.beacon.controlPort,
      );
      session = controller;
    } catch (e) {
      errorMessage = 'Failed to join session: $e';
    } finally {
      isConnecting = false;
      notifyListeners();
    }
  }

  Future<void> leave() async {
    session?.dispose();
    session = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _scanner.dispose();
    session?.dispose();
    super.dispose();
  }
}
