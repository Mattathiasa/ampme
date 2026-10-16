import 'dart:async';
import 'dart:io';

import 'package:ampme/core/network/control_server.dart';
import 'package:ampme/core/network/models/control_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer http;
  late ControlServer server;
  final incoming = <IncomingControlMessage>[];

  setUp(() async {
    server = ControlServer();
    incoming.clear();
    server.incoming.listen(incoming.add);
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      server.handleConnection(await WebSocketTransformer.upgrade(request));
    });
  });

  tearDown(() async {
    await server.dispose();
    await http.close(force: true);
  });

  /// A device that says hello as [id] and records what the host sends it.
  Future<({WebSocket socket, List<ControlMessage> heard, Future<void> closed})> device(
    String id,
  ) async {
    final socket = await WebSocket.connect('ws://127.0.0.1:${http.port}');
    final heard = <ControlMessage>[];
    final closed = Completer<void>();
    socket.listen(
      (data) => heard.add(ControlMessage.decode(data as String)),
      onDone: closed.complete,
    );
    socket.add(ControlMessage.clockSyncRequest(senderId: id, clientSendTimeMs: 1).encode());
    return (socket: socket, heard: heard, closed: closed.future);
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

  test('a removed device is told, disconnected, and others are left alone', () async {
    final a = await device('A');
    final b = await device('B');
    await settle();
    expect(server.connectedDeviceIds, {'A', 'B'});

    server.kick('A', hostId: 'host');
    await a.closed.timeout(const Duration(seconds: 2));

    expect(a.heard.map((m) => m.type), contains(ControlMessageType.removed));
    await settle();
    expect(server.connectedDeviceIds, {'B'});
    await b.socket.close();
  });

  test('a removed device that reconnects is refused and never reaches the host', () async {
    final a = await device('A');
    await settle();
    server.kick('A', hostId: 'host');
    await a.closed.timeout(const Duration(seconds: 2));
    final before = incoming.length;

    final again = await device('A');
    await again.closed.timeout(const Duration(seconds: 2));

    expect(again.heard.map((m) => m.type), contains(ControlMessageType.removed));
    expect(incoming.length, before, reason: 'its messages are dropped');
  });
}
