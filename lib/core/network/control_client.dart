import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'clock_sync.dart';
import 'models/control_message.dart';

const int _syncBurstCount = 8;
const Duration _syncBurstInterval = Duration(milliseconds: 200);
const Duration _syncSteadyInterval = Duration(seconds: 30);

/// Listener-side: owns the WebSocket connection to the host's control
/// channel, runs the NTP-style clock-sync exchange in the background, and
/// exposes the non-clock-sync messages (play/pause/seek/...) as a stream.
class ControlClient {
  ControlClient({required this.deviceId});

  final String deviceId;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _syncTimer;
  int _syncBurstRemaining = _syncBurstCount;

  final _estimator = ClockSyncEstimator();
  final _messageController = StreamController<ControlMessage>.broadcast();

  Stream<ControlMessage> get messages => _messageController.stream;
  ClockSyncEstimate? get clockEstimate => _estimator.currentEstimate;

  Future<void> connect({required String hostIp, required int controlPort}) async {
    await disconnect();
    final uri = Uri.parse('ws://$hostIp:$controlPort/control');
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _subscription = channel.stream.listen(_handleData, cancelOnError: false);
    _syncBurstRemaining = _syncBurstCount;
    _sendSyncRequest();
    _scheduleNextSync(_syncBurstInterval);
  }

  void _handleData(dynamic data) {
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
      return;
    }

    if (_messageController.isClosed) return;
    _messageController.add(message);
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
    _syncTimer?.cancel();
    _syncTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _estimator.reset();
  }

  Future<void> dispose() async {
    await disconnect();
    await _messageController.close();
  }
}
