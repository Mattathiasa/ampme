import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/session_beacon.dart';
import 'session_broadcaster.dart' show discoveryPort;

class DiscoveredSession {
  DiscoveredSession({required this.beacon, required this.lastSeenAt});

  final SessionBeacon beacon;
  final DateTime lastSeenAt;
}

const Duration _staleAfter = Duration(seconds: 5);
const Duration _sweepInterval = Duration(seconds: 1);

/// Listener-side: listens for [SessionBeacon] UDP broadcasts and exposes
/// the set of currently-visible "nearby sessions", expiring any host that
/// hasn't been heard from within [_staleAfter].
class SessionListenerScanner {
  RawDatagramSocket? _socket;
  Timer? _sweepTimer;
  final _sessions = <String, DiscoveredSession>{};
  final _controller = StreamController<List<DiscoveredSession>>.broadcast();

  Stream<List<DiscoveredSession>> get sessions => _controller.stream;

  Future<void> start() async {
    await stop();
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort);
    socket.broadcastEnabled = true;
    _socket = socket;
    socket.listen(_handleEvent);
    _sweepTimer = Timer.periodic(_sweepInterval, (_) => _sweepStale());
  }

  void _handleEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    final datagram = socket.receive();
    if (datagram == null) return;

    final beacon = SessionBeacon.tryParse(utf8.decode(datagram.data));
    if (beacon == null) return;

    _sessions[beacon.hostDeviceId] = DiscoveredSession(
      beacon: beacon,
      lastSeenAt: DateTime.now(),
    );
    _emit();
  }

  void _sweepStale() {
    final now = DateTime.now();
    final removed = _sessions.keys
        .where((id) => now.difference(_sessions[id]!.lastSeenAt) > _staleAfter)
        .toList();
    if (removed.isEmpty) return;
    removed.forEach(_sessions.remove);
    _emit();
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(_sessions.values.toList(growable: false));
  }

  Future<void> stop() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _socket?.close();
    _socket = null;
    _sessions.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
