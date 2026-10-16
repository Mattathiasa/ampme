import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/network/discovery/session_scanner.dart';
import '../../core/network/models/device_info.dart';
import '../../core/network/network_utils.dart';
import '../../core/network/signaling/cloud_signaling_channel.dart';
import '../../core/network/signaling/relay_signaling_channel.dart';
import '../../core/network/signaling/signaling_channel.dart';
import '../../core/observability/diagnostics.dart';
import '../../core/observability/reporting.dart';
import '../../core/permissions/app_permissions.dart';
import '../../core/session/active_session.dart';
import '../../core/session/listener_session_controller.dart';
import '../../core/session/sync_nudge_store.dart';
import '../../core/platform/audio_route.dart';
import '../../core/platform/session_keep_alive.dart';
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
          features: WebRtcListenerController.features,
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
      controller.addListener(_sessionChanged);
      await controller.connect(signaling);
      session = controller;
      await _applyRouteTiming();
      _keepAlive();
    } on SignalingException catch (e) {
      controller?.removeListener(_sessionChanged);
      controller?.dispose();
      errorMessage = e.message;
    } catch (e, st) {
      controller?.removeListener(_sessionChanged);
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
      controller.addListener(_sessionChanged);
      await controller.connect(hostIp: hostIp, controlPort: controlPort);
      session = controller;
      await _applyRouteTiming();
      _keepAlive();
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

  /// The text behind "Copy diagnostics": what this device knows about the
  /// session, then recent errors and sync readings.
  Future<String> diagnosticsReport() {
    final s = session;
    return Diagnostics.report(state: {
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'role': s == null
          ? 'not in a session'
          : s is WebRtcListenerController
              ? 'listener, browser-hosted session'
              : 'listener, phone-hosted session',
      if (s != null) ...{
        'session': s.sessionName ?? '-',
        'connection': s.hostLeft
            ? 'host left'
            : s.isReconnecting
                ? 'reconnecting'
                : s.connectProblem
                    ? 'cannot reach the host directly'
                    : 'connected',
        'playback': s.playbackState.name,
        'sync nudge ms': '${s.syncNudgeMs}',
        'clock offset ms': '${s.clockOffsetMs ?? '-'}',
        'round trip ms': '${s.roundTripMs ?? '-'}',
      },
      'output': outputRoute?.label ?? '-',
    });
  }

  /// Where this device's sound comes out; its saved timing is in use.
  AudioRoute? outputRoute;

  /// Set when the output changed mid-session (e.g. a Bluetooth speaker
  /// connected), for the UI to say so.
  String? routeNotice;

  StreamSubscription<AudioRoute>? _routeSub;
  Timer? _routeNoticeTimer;

  /// Loads the timing saved for the current output route, and follows the
  /// route for the rest of the session.
  Future<void> _applyRouteTiming() async {
    await _useRoute(await AudioRoutes.current());
    await _routeSub?.cancel();
    _routeSub = AudioRoutes.changes.listen((route) async {
      if (route == outputRoute || session == null) return;
      await _useRoute(route);
      final r = outputRoute;
      if (r == null) return;
      routeNotice = suggestCalibration
          ? 'Now playing through ${r.label}. It has its own delay — calibrate '
              'with the mic for it.'
          : 'Now playing through ${r.label}: using its saved timing.';
      _routeNoticeTimer?.cancel();
      _routeNoticeTimer = Timer(const Duration(seconds: 10), dismissRouteNotice);
      notifyListeners();
    });
  }

  Future<void> _useRoute(AudioRoute route) async {
    final saved = await SyncNudgeStore.load(route);
    outputRoute = route;
    session?.setSyncNudge(saved.ms);
    suggestCalibration = !saved.calibrated;
    notifyListeners();
  }

  void dismissRouteNotice() {
    if (routeNotice == null) return;
    routeNotice = null;
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
      // In a browser the output's name only shows once the mic was allowed:
      // look again, so this is saved for the named speaker.
      final route = await AudioRoutes.current();
      outputRoute = route;
      unawaited(SyncNudgeStore.save(route, nudge, calibrated: true));
      suggestCalibration = false;
      routeNotice = null;
      calibrationMessage = calibrationSummary(nudge, s.lastCalibrationRuns);
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
    unawaited(SyncNudgeStore.save(outputRoute ?? AudioRoute.fallback, s.syncNudgeMs));
  }

  Future<void> setVolume(double value) async {
    await session?.setLocalVolume(value);
  }

  /// Starts audio the browser refused to autoplay (call from a tap).
  Future<void> unlockAudio() async {
    await session?.unlockAudio();
  }

  Future<void> leave() async {
    unawaited(SessionKeepAlive.stop());
    unawaited(_routeSub?.cancel());
    _routeSub = null;
    _routeNoticeTimer?.cancel();
    outputRoute = null;
    routeNotice = null;
    session?.dispose();
    session = null;
    notifyListeners();
  }

  /// Keeps this device playing in sync with the screen off (Android): a
  /// notification with Leave, plus wake/Wi-Fi locks, while in the session.
  void _keepAlive() {
    unawaited(() async {
      await AppPermissions.requestNotificationAccess();
      // Left (or the host ended it) while the permission prompt was up.
      final current = session;
      if (current == null || current.hostLeft) return;
      await SessionKeepAlive.start(
        title: 'Ampme · ${current.sessionName ?? 'session'}',
        text: 'Playing in sync — keeps going with the screen off.',
        onLeave: () => unawaited(leave()),
      );
      notifyListeners(); // the page may need its keep-the-screen-on hint
    }());
  }

  void _sessionChanged() {
    // The host ended it: nothing left to keep alive.
    if (session?.hostLeft ?? false) unawaited(SessionKeepAlive.stop());
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(SessionKeepAlive.stop());
    unawaited(_routeSub?.cancel());
    _routeNoticeTimer?.cancel();
    _scanner.dispose();
    session?.dispose();
    super.dispose();
  }
}

/// The calibration outcome for the UI, with each reading so a bad
/// measurement is visible rather than a silent "in step".
String calibrationSummary(int nudge, List<int> runs) {
  final readings = runs.isEmpty ? '' : ' (readings: ${runs.join(', ')} ms)';
  final spread = runs.isEmpty
      ? 0
      : runs.reduce((a, b) => a > b ? a : b) - runs.reduce((a, b) => a < b ? a : b);
  final verdict = nudge.abs() < 5
      ? 'Measured: this device is in step with the host'
      : 'Measured: this device sounded ${nudge.abs()} ms '
            '${nudge > 0 ? 'late' : 'early'} — corrected';
  final warn = spread > 30 ? ' The readings disagreed — try again nearer the host.' : '';
  return '$verdict$readings.$warn';
}
