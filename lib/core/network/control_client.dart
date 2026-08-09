import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'clock_sync.dart';
import 'models/control_message.dart';
import 'network_utils.dart';

const int _syncBurstCount = 8;
const Duration _syncBurstInterval = Duration(milliseconds: 200);
// Steady-state samples every 2s (was 10s) so the estimator always carries a
// *current* offset while playing — the listener's drift-correction loop and
// every host-time conversion depend on it, and a stale offset estimate is
// what turns a phone clock that's seconds off into audible playback lag.
// Cost on a LAN is trivial: one tiny request/response pair per device.
const Duration _syncSteadyInterval = Duration(seconds: 2);

/// Reconnection lifecycle reported to the session controller while the client
/// tries to recover from a transient drop (WiFi blip, host briefly
/// backgrounded) before giving up and reporting the host as gone.
enum ReconnectionStatus { attempting, succeeded, failed }

/// Exponential-backoff delays between reconnection attempts (1s, 2s, 4s).
const List<Duration> _reconnectDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];

/// How long a reconnection attempt waits for proof the new socket is actually
/// live (the first control frame) before treating it as a failed attempt.
const Duration _reconnectProbeTimeout = Duration(seconds: 2);

/// Listener-side: owns the WebSocket connection to the host's control
/// channel, runs the NTP-style clock-sync exchange in the background, and
/// exposes the non-clock-sync messages (play/pause/seek/...) as a stream.
///
/// Transient drops (WiFi blip, host briefly backgrounded) are recovered
/// automatically: the client reconnects with exponential backoff and only
/// reports the host as gone ([disconnected]) after every attempt fails.
class ControlClient {
  ControlClient({required this.deviceId});

  final String deviceId;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _syncTimer;
  int _syncBurstRemaining = _syncBurstCount;
  String? _hostIp;
  int? _controlPort;

  /// True once any control frame arrives, which only happens on a live
  /// connection — lets us fail fast when the host was never reachable.
  bool _everReceivedData = false;

  /// Bumped on every connect/disconnect so a stale reconnection loop from an
  /// aborted session can never resurrect itself.
  int _generation = 0;
  bool _reconnecting = false;
  bool _disposed = false;

  final _estimator = ClockSyncEstimator();
  final _messageController = StreamController<ControlMessage>.broadcast();
  final _disconnectedController = StreamController<void>.broadcast();
  final _reconnectionController =
      StreamController<ReconnectionStatus>.broadcast();
  bool _disconnectedEmitted = false;

  Stream<ControlMessage> get messages => _messageController.stream;

  /// Fires only after every reconnection attempt has failed — i.e. the host
  /// is really gone, not just briefly unreachable.
  Stream<void> get disconnected => _disconnectedController.stream;

  /// Emits [ReconnectionStatus.attempting]/[succeeded]/[failed] while a
  /// transient drop is being recovered.
  Stream<ReconnectionStatus> get reconnectionStatus =>
      _reconnectionController.stream;

  ClockSyncEstimate? get clockEstimate => _estimator.currentEstimate;

  /// Number of clock-sync samples collected so far this session — lets the
  /// session controller tell "a fresh estimate is arriving" from "no data
  /// yet" when it schedules a synchronized start.
  int get syncSampleCount => _estimator.sampleCount;

  /// Wall-clock time the most recent clock-sync sample was recorded at.
  /// Lets callers skip a sync burst when the estimate is already current
  /// (the steady-state sync runs every 2s, so a <1s-old offset is plenty
  /// accurate for a scheduled start — waiting for new samples would just eat
  /// into the scheduling lead and turn into audible late starts).
  DateTime? _lastSyncSampleAt;

  /// Whether the estimator already holds a sample young enough to convert
  /// host times with, so callers can skip [syncNow]'s fresh-burst wait.
  bool isSyncFresh({Duration within = const Duration(milliseconds: 600)}) {
    final t = _lastSyncSampleAt;
    return t != null && DateTime.now().difference(t) <= within;
  }

  /// Restarts the clock-sync burst immediately. Called right before a
  /// scheduled start, where offset error converts directly into playback
  /// lag: a fresh burst yields low-latency samples within a few hundred ms
  /// (inside the scheduling lead time), so the host->local time conversion
  /// uses a current offset rather than a stale or zero one.
  void syncNow() {
    _syncTimer?.cancel();
    _syncBurstRemaining = _syncBurstCount;
    _sendSyncRequest();
    _scheduleNextSync(_syncBurstInterval);
  }

  Future<void> connect({required String hostIp, required int controlPort}) async {
    // Ampme is LAN-only: never open a control connection to anything but a
    // private/loopback address. See network_security_config.xml for the
    // platform-side rationale.
    if (!isPrivateNetworkHost(hostIp)) {
      throw ArgumentError.value(
        hostIp,
        'hostIp',
        'Host is not on a private network (RFC 1918)',
      );
    }
    await disconnect();
    _hostIp = hostIp;
    _controlPort = controlPort;
    _everReceivedData = false;
    _disconnectedEmitted = false;
    await _openChannel();
  }

  Future<void> _openChannel() async {
    final hostIp = _hostIp!;
    final controlPort = _controlPort!;
    final uri = Uri.parse('ws://$hostIp:$controlPort/control');
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _subscription = channel.stream.listen(
      _handleData,
      onDone: _handleClosed,
      onError: (_) => _handleClosed(),
      cancelOnError: false,
    );
    _syncBurstRemaining = _syncBurstCount;
    _sendSyncRequest();
    _scheduleNextSync(_syncBurstInterval);
  }

  void _handleData(dynamic data) {
    _everReceivedData = true;
    if (data is! String) return;

    final ControlMessage message;
    try {
      message = ControlMessage.decode(data);
    } catch (_) {
      return; // drop malformed frame
    }

    if (message.type == ControlMessageType.clockSyncResponse) {
      final t0 = message.payload['clientSendTimeMs'] as int;
      final t1 = message.payload['hostTimeMs'] as int;
      final t2 = DateTime.now().millisecondsSinceEpoch;
      _estimator.addSample(ClockSyncSample(t0: t0, t1: t1, t2: t2));
      _lastSyncSampleAt = DateTime.now();
      return;
    }

    if (_messageController.isClosed) return;
    _messageController.add(message);
  }

  void _handleClosed() {
    if (_disposed) return;
    if (_channel == null) return; // already handled, or user-initiated close
    _channel = null;
    unawaited(_subscription?.cancel());
    _subscription = null;

    // The connection never delivered a single frame (dead host, bad port) —
    // fail fast instead of retrying a session that never existed.
    if (!_everReceivedData) {
      _emitDisconnected();
      return;
    }
    unawaited(_attemptReconnect());
  }

  Future<void> _attemptReconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    final generation = _generation;
    try {
      for (var i = 0; i < _reconnectDelays.length; i++) {
        if (_isStale(generation)) return;
        _reconnectionController.add(ReconnectionStatus.attempting);
        await Future<void>.delayed(_reconnectDelays[i]);
        if (_isStale(generation)) return;

        try {
          await _openChannel();
        } catch (_) {
          continue; // immediate failure — try the next backoff delay
        }
        // WebSocketChannel.connect resolves optimistically; wait for proof the
        // socket is live (first control frame) before declaring success.
        final alive = await _waitForFirstFrame(generation);
        if (!alive) {
          await _teardownChannel();
          continue;
        }
        _reconnectionController.add(ReconnectionStatus.succeeded);
        return;
      }
      if (_isStale(generation)) return;
      _reconnectionController.add(ReconnectionStatus.failed);
      _emitDisconnected();
    } finally {
      _reconnecting = false;
    }
  }

  /// Polls until the first control frame arrives, the socket dies, the client
  /// is torn down, or [generation] changes — whichever comes first.
  Future<bool> _waitForFirstFrame(int generation) async {
    final deadline = DateTime.now().add(_reconnectProbeTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_isStale(generation)) return false;
      if (_channel == null) return false; // socket closed again
      if (_everReceivedData) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  bool _isStale(int generation) => _disposed || generation != _generation;

  Future<void> _teardownChannel() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void _emitDisconnected() {
    if (_disconnectedEmitted || _disconnectedController.isClosed) return;
    _disconnectedEmitted = true;
    _disconnectedController.add(null);
  }

  void _scheduleNextSync(Duration delay) {
    _syncTimer = Timer(delay, () {
      _sendSyncRequest();
      if (_syncBurstRemaining > 0) _syncBurstRemaining--;
      final nextDelay = _syncBurstRemaining > 0 ? _syncBurstInterval : _syncSteadyInterval;
      _scheduleNextSync(nextDelay);
    });
  }

  void _sendSyncRequest() {
    send(
      ControlMessage.clockSyncRequest(
        senderId: deviceId,
        clientSendTimeMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void send(ControlMessage message) {
    _channel?.sink.add(message.encode());
  }

  Future<void> disconnect() async {
    // Abort any in-flight reconnection loop from this session.
    _generation++;
    _syncTimer?.cancel();
    _syncTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _estimator.reset();
    _lastSyncSampleAt = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _messageController.close();
    await _disconnectedController.close();
    await _reconnectionController.close();
  }
}
