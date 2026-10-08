import 'dart:async';

import 'clock_sync.dart';
import 'control_link.dart';
import 'models/control_message.dart';

const int _syncBurstCount = 8;
const Duration _syncBurstInterval = Duration(milliseconds: 200);
const Duration _syncSteadyInterval = Duration(seconds: 2);

/// A [ControlLink] over any ordered text pipe — in practice a WebRTC data
/// channel to a browser host. The pipe's owner feeds frames in through
/// [incoming], reports connectivity through [setReconnecting]/[close], and
/// this class runs the same clock-sync schedule as [ControlClient].
class PipeControlLink implements ControlLink {
  PipeControlLink({
    required this.deviceId,
    required Stream<String> incoming,
    required this.sendFrame,
  }) {
    _incomingSub = incoming.listen(_handleFrame, onDone: close);
    syncNow();
  }

  final String deviceId;
  final void Function(String frame) sendFrame;
  late final StreamSubscription<String> _incomingSub;

  final _estimator = ClockSyncEstimator();
  final _messageController = StreamController<ControlMessage>.broadcast();
  final _disconnectedController = StreamController<void>.broadcast();
  final _reconnectionController =
      StreamController<ReconnectionStatus>.broadcast();
  Timer? _syncTimer;
  int _syncBurstRemaining = _syncBurstCount;
  DateTime? _lastSyncSampleAt;
  bool _reconnecting = false;
  bool _closed = false;

  @override
  Stream<ControlMessage> get messages => _messageController.stream;

  @override
  Stream<void> get disconnected => _disconnectedController.stream;

  @override
  Stream<ReconnectionStatus> get reconnectionStatus =>
      _reconnectionController.stream;

  @override
  ClockSyncEstimate? get clockEstimate => _estimator.currentEstimate;

  @override
  int get syncSampleCount => _estimator.sampleCount;

  @override
  bool isSyncFresh({Duration within = const Duration(milliseconds: 600)}) {
    final t = _lastSyncSampleAt;
    return t != null && DateTime.now().difference(t) <= within;
  }

  @override
  void syncNow() {
    if (_closed) return;
    _syncTimer?.cancel();
    _syncBurstRemaining = _syncBurstCount;
    _sendSyncRequest();
    _scheduleNextSync(_syncBurstInterval);
  }

  /// Drops every clock sample and starts a fresh burst. Used after the song
  /// transfer: samples taken while megabytes were queued on the link have
  /// inflated, lopsided round trips that would skew the offset.
  void resetSync() {
    _estimator.reset();
    _lastSyncSampleAt = null;
    syncNow();
  }

  void _scheduleNextSync(Duration delay) {
    _syncTimer = Timer(delay, () {
      _sendSyncRequest();
      if (_syncBurstRemaining > 0) _syncBurstRemaining--;
      _scheduleNextSync(
        _syncBurstRemaining > 0 ? _syncBurstInterval : _syncSteadyInterval,
      );
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

  void _handleFrame(String frame) {
    if (_closed) return;
    final ControlMessage message;
    try {
      message = ControlMessage.decode(frame);
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
    _messageController.add(message);
  }

  /// The pipe's connection is temporarily down ([value] true) or back up.
  /// Coming back triggers a fresh sync burst: the offset may have moved.
  void setReconnecting(bool value) {
    if (_closed || value == _reconnecting) return;
    _reconnecting = value;
    _reconnectionController.add(
      value ? ReconnectionStatus.attempting : ReconnectionStatus.succeeded,
    );
    if (!value) syncNow();
  }

  @override
  void send(ControlMessage message) {
    if (_closed) return;
    try {
      sendFrame(message.encode());
    } catch (_) {
      // Channel closing; the owner reports that through [close].
    }
  }

  /// The host is gone for good: stops syncing and fires [disconnected].
  void close() {
    if (_closed) return;
    if (_reconnecting) {
      _reconnectionController.add(ReconnectionStatus.failed);
    }
    _closed = true;
    _syncTimer?.cancel();
    _disconnectedController.add(null);
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _syncTimer?.cancel();
    await _incomingSub.cancel();
    await _messageController.close();
    await _disconnectedController.close();
    await _reconnectionController.close();
  }
}
