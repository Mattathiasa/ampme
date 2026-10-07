import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'signaling_channel.dart';

/// [SignalingChannel] over the LAN relay (`tool/web_relay.dart`) — plain
/// `ws://` on the local network, no cloud involved.
///
/// Browsers only allow this from pages served over plain HTTP (the relay
/// serves the app that way); an HTTPS page is blocked by mixed-content rules.
class RelaySignalingChannel implements SignalingChannel {
  RelaySignalingChannel({
    required this.relayHost,
    required this.relayPort,
    required this.code,
    required this.role,
    required this.selfId,
    this.deviceName = '',
    this.sessionName = '',
    this.connectTimeout = const Duration(seconds: 10),
  });

  final String relayHost;
  final int relayPort;
  final String code;
  final SignalingRole role;
  final String selfId;
  final String deviceName;
  final String sessionName;
  final Duration connectTimeout;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _disconnected = StreamController<void>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Completer<Map<String, dynamic>>? _welcome;
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Stream<void> get disconnected => _disconnected.stream;

  Uri get uri => Uri.parse('ws://$relayHost:$relayPort/ws');

  @override
  Future<Map<String, dynamic>> connect() async {
    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(uri);
    } catch (e) {
      // Browsers throw synchronously for ws:// from an https:// page.
      throw SignalingException('Could not open the relay connection ($uri): $e');
    }
    _channel = channel;
    final welcome = Completer<Map<String, dynamic>>();
    _welcome = welcome;
    _sub = channel.stream.listen(
      _handleData,
      onDone: _handleClosed,
      onError: (_) => _handleClosed(),
      cancelOnError: false,
    );
    _sendRaw(
      role == SignalingRole.host
          ? {'type': 'host', 'code': code, 'sessionName': sessionName}
          : {
              'type': 'listener',
              'code': code,
              'id': selfId,
              'deviceName': deviceName,
            },
    );
    try {
      return await welcome.future.timeout(connectTimeout);
    } on TimeoutException {
      await close();
      throw const SignalingException('The relay or session is unreachable.');
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _handleData(dynamic data) {
    if (data is! String) return;
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return; // drop malformed frames
    }
    final welcome = _welcome;
    if (welcome != null && !welcome.isCompleted) {
      switch (message['type']) {
        case 'welcome':
          welcome.complete(message);
          return;
        case 'no-host':
          welcome.completeError(const SignalingException('Session not found.'));
          return;
        case 'error':
          welcome.completeError(
            SignalingException(message['message'] as String? ?? 'Relay error.'),
          );
          return;
      }
    }
    if (!_messages.isClosed) _messages.add(message);
  }

  void _handleClosed() {
    final welcome = _welcome;
    if (welcome != null && !welcome.isCompleted) {
      welcome.completeError(
        const SignalingException('Could not reach the relay.'),
      );
      return;
    }
    if (!_closed && !_disconnected.isClosed) _disconnected.add(null);
  }

  @override
  void send(Map<String, dynamic> message) {
    _sendRaw({
      ...message,
      'code': code,
      if (role == SignalingRole.listener) 'from': selfId,
    });
  }

  void _sendRaw(Map<String, dynamic> message) {
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {
      // Relay gone; already-connected peers keep streaming directly.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    _sub = null;
    try {
      // A socket that never opened may never report closure; don't hang.
      await _channel?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Already closed / timed out.
    }
    _channel = null;
    await _messages.close();
    await _disconnected.close();
  }
}
