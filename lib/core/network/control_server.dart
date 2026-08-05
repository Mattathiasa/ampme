import 'dart:async';
import 'dart:io';

import 'models/control_message.dart';

class IncomingControlMessage {
  const IncomingControlMessage({required this.deviceId, required this.message});

  final String deviceId;
  final ControlMessage message;
}

/// Host-side: tracks connected listener WebSockets (keyed by the
/// `senderId` each listener stamps on its messages) and lets the host
/// broadcast or address control messages to them.
///
/// Sockets are handed off from [AudioHttpServer]'s upgrade handling; this
/// class owns only the control-message layer, not the HTTP server itself.
class ControlServer {
  final _sockets = <String, WebSocket>{};
  final _socketDeviceIds = <WebSocket, String>{};
  final _controller = StreamController<IncomingControlMessage>.broadcast();
  final _disconnectController = StreamController<String>.broadcast();

  Stream<IncomingControlMessage> get incoming => _controller.stream;

  /// Emits a listener's deviceId when its socket closes, so callers can
  /// drop stale UI state for it.
  Stream<String> get disconnections => _disconnectController.stream;

  Set<String> get connectedDeviceIds => _sockets.keys.toSet();

  void handleConnection(WebSocket socket) {
    socket.listen(
      (data) => _handleData(socket, data),
      onDone: () => _handleDisconnect(socket),
      onError: (_) => _handleDisconnect(socket),
      cancelOnError: true,
    );
  }

  void _handleData(WebSocket socket, dynamic data) {
    if (data is! String) return;

    final ControlMessage message;
    try {
      message = ControlMessage.decode(data);
    } catch (_) {
      return; // drop malformed frame rather than crashing the session
    }

    _sockets[message.senderId] = socket;
    _socketDeviceIds[socket] = message.senderId;
    if (_controller.isClosed) return;
    _controller.add(IncomingControlMessage(deviceId: message.senderId, message: message));
  }

  void _handleDisconnect(WebSocket socket) {
    _sockets.removeWhere((_, s) => s == socket);
    final deviceId = _socketDeviceIds.remove(socket);
    if (deviceId != null && !_disconnectController.isClosed) {
      _disconnectController.add(deviceId);
    }
  }

  void sendTo(String deviceId, ControlMessage message) {
    _sockets[deviceId]?.add(message.encode());
  }

  void broadcast(ControlMessage message) {
    final data = message.encode();
    for (final socket in _sockets.values) {
      socket.add(data);
    }
  }

  Future<void> dispose() async {
    for (final socket in _sockets.values) {
      await socket.close();
    }
    _sockets.clear();
    _socketDeviceIds.clear();
    await _controller.close();
    await _disconnectController.close();
  }
}
