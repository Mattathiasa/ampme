import 'package:flutter/foundation.dart';

import '../../core/network/discovery/session_scanner.dart';
import '../../core/network/models/device_info.dart';
import '../../core/permissions/app_permissions.dart';
import '../../core/session/listener_session_controller.dart';
import '../../utils/id_generator.dart';
import '../../utils/join_code.dart';
import '../../utils/platform_info.dart';

/// Wraps session discovery (browsing "nearby sessions") and, once the
/// user picks one, the [ListenerSessionController] that actually joins
/// and plays it.
class JoinViewModel extends ChangeNotifier {
  JoinViewModel()
    : selfDevice = DeviceInfo(
        deviceId: generateId(),
        deviceName: 'Listener-${generateId().substring(0, 4)}',
        platform: currentPlatformName(),
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
    // Discovery is best-effort: a denied permission or a socket that won't
    // bind shouldn't crash the screen — the user can still join by code.
    try {
      await AppPermissions.requestLocalNetworkAccess();
      await _scanner.start();
      isScanning = true;
      _scanner.sessions.listen((sessions) {
        nearbySessions = sessions;
        notifyListeners();
      });
    } catch (_) {
      // Leave isScanning false; join-by-code remains available.
    }
    notifyListeners();
  }

  Future<void> stopScanning() async {
    await _scanner.stop();
    isScanning = false;
    notifyListeners();
  }

  /// Join a session discovered over UDP (native only).
  Future<void> join(DiscoveredSession discovered) =>
      _connect(hostIp: discovered.beacon.hostIp, controlPort: discovered.beacon.controlPort);

  /// Join by a code the host displays (e.g. `192.168.1.5:54213`, an
  /// `ampme://join?...` link, or `http://ip:port`). This is the only join
  /// path available on web, where UDP discovery isn't possible.
  Future<void> joinByCode(String code) async {
    final address = parseJoinCode(code);
    if (address == null) {
      errorMessage = 'That doesn’t look like a valid session code.';
      notifyListeners();
      return;
    }
    await _connect(hostIp: address.host, controlPort: address.port);
  }

  Future<void> _connect({required String hostIp, required int controlPort}) async {
    isConnecting = true;
    errorMessage = null;
    notifyListeners();
    try {
      await AppPermissions.requestLocalNetworkAccess();
      await stopScanning();

      final controller = ListenerSessionController(selfDevice: selfDevice);
      controller.addListener(notifyListeners);
      await controller.connect(hostIp: hostIp, controlPort: controlPort);
      session = controller;
    } catch (e) {
      errorMessage = 'Failed to join session: $e';
    } finally {
      isConnecting = false;
      notifyListeners();
    }
  }

  /// Sets this device's local playback volume (per-device, doesn't affect the
  /// host or other listeners).
  Future<void> setVolume(double value) async {
    await session?.setLocalVolume(value);
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
