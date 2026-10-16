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

  /// Every connected socket, identified or not.
  final _open = <WebSocket>{};
  final _controller = StreamController<IncomingControlMessage>.broadcast();
  final _disconnectController = StreamController<String>.broadcast();

  /// Devices the host removed: they are told so and refused from then on.
  final _blocked = <String>{};

  Stream<IncomingControlMessage> get incoming => _controller.stream;

  /// Emits a listener's deviceId when its socket closes, so callers can
  /// drop stale UI state for it.
  Stream<String> get disconnections => _disconnectController.stream;

  Set<String> get connectedDeviceIds => _sockets.keys.toSet();

  /// Most listeners at once, and the largest control frame accepted: a
  /// stranger on the network can open sockets and send frames too.
  static const int maxConnections = 64;
  static const int maxFrameChars = 64 * 1024;

  void handleConnection(WebSocket socket) {
    if (_open.length >= maxConnections) {
      unawaited(socket.close(WebSocketStatus.policyViolation, 'Too many listeners'));
      return;
    }
    _open.add(socket);
    socket.listen(
      (data) => _handleData(socket, data),
      onDone: () => _handleDisconnect(socket),
      onError: (_) => _handleDisconnect(socket),
      cancelOnError: true,
    );
  }

  void _handleData(WebSocket socket, dynamic data) {
    if (data is! String || data.length > maxFrameChars) return;

    final ControlMessage message;
    try {
      message = ControlMessage.decode(data);
    } catch (_) {
      return; // drop malformed frame rather than crashing the session
    }

    // A connection keeps the identity it first claimed: it can't start
    // speaking as another device. (A *new* connection claiming an id replaces
    // the old one — that is how a reconnecting device takes its place back.)
    final bound = _socketDeviceIds[socket];
    if (bound != null && bound != message.senderId) return;
    if (_blocked.contains(message.senderId)) {
      // Back after being removed: say so again and hang up.
      _send(socket, ControlMessage.removed(senderId: _hostId ?? '').encode());
      unawaited(socket.close(WebSocketStatus.policyViolation, 'Removed'));
      return;
    }
    _sockets[message.senderId] = socket;
    _socketDeviceIds[socket] = message.senderId;
    if (_controller.isClosed) return;
    _controller.add(IncomingControlMessage(deviceId: message.senderId, message: message));
  }

  void _handleDisconnect(WebSocket socket) {
    _open.remove(socket);
    _sockets.removeWhere((_, s) => s == socket);
    final deviceId = _socketDeviceIds.remove(socket);
    if (deviceId != null && !_disconnectController.isClosed) {
      _disconnectController.add(deviceId);
    }
  }

  String? _hostId;

  /// Removes [deviceId]: tells it, closes its connection, and refuses it if
  /// it reconnects. [hostId] is the sender id the removal message carries.
  void kick(String deviceId, {required String hostId}) {
    _hostId = hostId;
    _blocked.add(deviceId);
    final socket = _sockets[deviceId];
    if (socket == null) return;
    _send(socket, ControlMessage.removed(senderId: hostId).encode());
    // Closing right after the frame is written still delivers it.
    unawaited(socket.close(WebSocketStatus.policyViolation, 'Removed').catchError((Object _) {}));
  }

  void sendTo(String deviceId, ControlMessage message) {
    _send(_sockets[deviceId], message.encode());
  }

  void broadcast(ControlMessage message) {
    final data = message.encode();
    for (final socket in _sockets.values.toList()) {
      _send(socket, data);
    }
  }

  /// One dead socket must not stop the others from being told.
  void _send(WebSocket? socket, String data) {
    try {
      socket?.add(data);
    } catch (_) {
      // Closing; its onDone/onError reports the disconnect.
    }
  }

  Future<void> dispose() async {
    for (final socket in _sockets.values) {
      await socket.close();
    }
    _sockets.clear();
    _socketDeviceIds.clear();
    _open.clear();
    await _controller.close();
    await _disconnectController.close();
  }
}
