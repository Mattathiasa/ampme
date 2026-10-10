import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/network/discovery/session_scanner.dart';
import '../../core/network/models/device_info.dart';
import '../../core/network/network_utils.dart';
import '../../core/network/signaling/cloud_signaling_channel.dart';
import '../../core/network/signaling/relay_signaling_channel.dart';
import '../../core/network/signaling/signaling_channel.dart';
import '../../core/observability/reporting.dart';
import '../../core/permissions/app_permissions.dart';
import '../../core/session/active_session.dart';
import '../../core/session/listener_session_controller.dart';
import '../../core/session/sync_nudge_store.dart';
import '../../core/sync/acoustic_calibration.dart';
import '../../core/session/web_rtc_listener_controller.dart';
import '../../utils/id_generator.dart';
import '../../utils/join_code.dart';
import '../../utils/platform_info.dart';

/// Whether this is the web build served over HTTPS (e.g. GitHub Pages).
/// Browsers block such pages from opening plain `ws://`/`http://`
/// connections to LAN devices (mixed content), so LAN-only join paths are
/// rejected up front with an explanation instead of failing obscurely.
bool get _isSecureWebPage => kIsWeb && Uri.base.scheme == 'https';

const _lanFromHttpsMessage =
    'This copy of the web app is served over HTTPS, and browsers block it '
    'from reaching devices on your WiFi. Ask the host for an AMP- code '
    '(hosted from the web app), use the Ampme Android/Windows app, or open '
    'the web app from the LAN relay (dart run tool/web_relay.dart).';

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
  ActiveSession? session;
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
    } catch (e, st) {
      // Leave isScanning false; join-by-code remains available.
      reportError(e, st, context: 'startScanning');
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

  /// Join by a code the host displays. Three formats are accepted, tried in
  /// this order:
  ///
  /// - web-hosted session (cloud): `AMP-7KQ4ZD`, or a join link
  ///   `https://…/web/?join=AMP-7KQ4ZD` — joined over WebRTC, signaled via
  ///   Supabase Realtime (works from anywhere, HTTPS pages included);
  /// - web-hosted session (LAN relay): `192.168.1.10:8080/AMP-4821` (relay
  ///   address + session token) — joined over WebRTC via the LAN relay;
  /// - native session: `192.168.1.5:54213` (an `ampme://join?...` link, or
  ///   `http://ip:port`), joined over WebSocket/HTTP.
  ///
  /// This is the only join path available on web, where UDP discovery isn't
  /// possible.
  Future<void> joinByCode(String code) async {
    final cloudCode = parseCloudSessionCode(code);
    if (cloudCode != null) {
      await _connectWebSession(
        CloudSignalingChannel(
          code: cloudCode,
          role: SignalingRole.listener,
          selfId: selfDevice.deviceId,
          deviceName: selfDevice.deviceName,
        ),
      );
      return;
    }

    // LAN-relay web sessions: their code has a `/token` after the port.
    final webSession = parseWebSessionCode(code);
    if (webSession != null) {
      if (_isSecureWebPage) {
        errorMessage = _lanFromHttpsMessage;
        notifyListeners();
        return;
      }
      if (!isPrivateNetworkHost(webSession.relayHost)) {
        errorMessage = 'That relay isn’t on a private network — Ampme only works over local WiFi.';
        notifyListeners();
        return;
      }
      await _connectWebSession(
        RelaySignalingChannel(
          relayHost: webSession.relayHost,
          relayPort: webSession.relayPort,
          code: webSession.code,
          role: SignalingRole.listener,
          selfId: selfDevice.deviceId,
          deviceName: selfDevice.deviceName,
        ),
      );
      return;
    }

    final address = parseJoinCode(code);
    if (address == null) {
      errorMessage = 'That doesn’t look like a valid session code.';
      notifyListeners();
      return;
    }
    if (_isSecureWebPage) {
      errorMessage = _lanFromHttpsMessage;
      notifyListeners();
      return;
    }
    // LAN-only: join codes pointing outside the private ranges are rejected
    // up front (the connect path enforces the same rule as a backstop).
    if (!isPrivateNetworkHost(address.host)) {
      errorMessage = 'That host isn’t on a private network — Ampme only works over local WiFi.';
      notifyListeners();
      return;
    }
    await _connect(hostIp: address.host, controlPort: address.port);
  }

  /// Joins a browser-hosted session over [signaling] (cloud or LAN relay).
  Future<void> _connectWebSession(SignalingChannel signaling) async {
    isConnecting = true;
    errorMessage = null;
    notifyListeners();
    WebRtcListenerController? controller;
    try {
      await stopScanning();
      controller = WebRtcListenerController(selfDevice: selfDevice);
      controller.addListener(notifyListeners);
      await controller.connect(signaling);
      session = controller;
      controller.setSyncNudge(await SyncNudgeStore.load());
      suggestCalibration = !await SyncNudgeStore.loadCalibrated();
    } on SignalingException catch (e) {
      controller?.removeListener(notifyListeners);
      controller?.dispose();
      errorMessage = e.message;
    } catch (e, st) {
      controller?.removeListener(notifyListeners);
      controller?.dispose();
      errorMessage = 'Failed to join web session: $e';
      reportError(e, st, context: 'joinWebSession');
    } finally {
      isConnecting = false;
      notifyListeners();
    }
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
      controller.setSyncNudge(await SyncNudgeStore.load());
      suggestCalibration = !await SyncNudgeStore.loadCalibrated();
    } catch (e, st) {
      errorMessage = 'Failed to join session: $e';
      reportError(e, st, context: 'joinSession');
    } finally {
      isConnecting = false;
      notifyListeners();
    }
  }

  /// Sets this device's local playback volume (per-device, doesn't affect the
  /// host or other listeners).
  /// Mic calibration progress: the run in progress (0-2), or null.
  int? calibrationRun;

  /// The outcome of the last calibration, for the UI.
  String? calibrationMessage;

  /// True until this device has calibrated once (or the hint is dismissed):
  /// the join screen suggests it, since speaker delay is the one part of
  /// sync only the mic can measure.
  bool suggestCalibration = false;

  void dismissCalibrationHint() {
    suggestCalibration = false;
    notifyListeners();
  }

  /// Measures this device's speaker delay with the mic and sets the nudge.
  Future<void> calibrateWithMic({BuildContext? context}) async {
    final s = session;
    if (s == null || calibrationRun != null) return;
    final granted = await AppPermissions.requestMicrophoneAccess(
      context: context,
      title: 'Microphone access is needed',
      message: 'Ampme listens for two short test sounds to measure how late '
          'this device plays. Nothing is recorded or sent anywhere.',
    );
    if (!granted) {
      calibrationMessage = 'Calibration needs the microphone.';
      notifyListeners();
      return;
    }
    calibrationRun = 0;
    calibrationMessage = null;
    notifyListeners();
    try {
      final nudge = await s.calibrateWithMic(onRun: (run) {
        calibrationRun = run;
        notifyListeners();
      });
      unawaited(SyncNudgeStore.save(nudge));
      unawaited(SyncNudgeStore.saveCalibrated());
      suggestCalibration = false;
      calibrationMessage = nudge == 0
          ? 'Measured: this device is already in step.'
          : 'Measured: this device sounded ${nudge.abs()} ms '
              '${nudge > 0 ? 'late' : 'early'} — corrected.';
    } on CalibrationException catch (e) {
      calibrationMessage = e.message;
    } catch (e, st) {
      calibrationMessage = 'Calibration failed: $e';
      reportError(e, st, context: 'calibrateWithMic');
    } finally {
      calibrationRun = null;
      notifyListeners();
    }
  }

  /// Shifts this device earlier/later to match the room by ear; remembered.
  void setSyncNudge(int ms) {
    final s = session;
    if (s == null) return;
    s.setSyncNudge(ms);
    unawaited(SyncNudgeStore.save(s.syncNudgeMs));
  }

  Future<void> setVolume(double value) async {
    await session?.setLocalVolume(value);
  }

  /// Starts audio the browser refused to autoplay (call from a tap).
  Future<void> unlockAudio() async {
    await session?.unlockAudio();
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
