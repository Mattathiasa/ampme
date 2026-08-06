import 'dart:async';

import 'discovered_session.dart';

export 'discovered_session.dart';

/// Web no-op stand-in for the native UDP [SessionListenerScanner]. Browsers
/// can't open raw datagram sockets, so auto-discovery is unavailable on web
/// and the scanner never emits any sessions; web users join by code instead.
class SessionListenerScanner {
  final _controller = StreamController<List<DiscoveredSession>>.broadcast();

  Stream<List<DiscoveredSession>> get sessions => _controller.stream;

  Future<void> start() async {}

  Future<void> stop() async {}

  Future<void> dispose() async {
    await _controller.close();
  }
}
