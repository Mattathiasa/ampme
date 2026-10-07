import 'dart:async';

import 'package:ampme/core/network/signaling/cloud_signaling_channel.dart';
import 'package:ampme/core/network/signaling/signaling_channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in for a Supabase Realtime broadcast room: every message
/// is delivered (asynchronously, like the network) to every *other* member
/// of the same topic.
class _FakeHub {
  final _members = <_FakeTransport>[];
  final sent = <Map<String, dynamic>>[];

  _FakeTransport transport() => _FakeTransport(this);

  void _publish(_FakeTransport from, Map<String, dynamic> message) {
    sent.add(message);
    for (final member in List.of(_members)) {
      if (member == from || member._topic != from._topic) continue;
      final onMessage = member._onMessage;
      if (onMessage != null) {
        scheduleMicrotask(() => onMessage(Map<String, dynamic>.from(message)));
      }
    }
  }
}

class _FakeTransport implements BroadcastTransport {
  _FakeTransport(this._hub);

  final _FakeHub _hub;
  final _dropped = StreamController<void>.broadcast();
  String? _topic;
  void Function(Map<String, dynamic>)? _onMessage;
  bool failJoin = false;

  @override
  Future<void> join(
    String topic,
    void Function(Map<String, dynamic>) onMessage,
  ) async {
    if (failJoin) throw const SignalingException('unreachable');
    _topic = topic;
    _onMessage = onMessage;
    _hub._members.add(this);
  }

  @override
  void broadcast(Map<String, dynamic> message) {
    if (_topic == null) return;
    _hub._publish(this, message);
  }

  @override
  Stream<void> get dropped => _dropped.stream;

  void drop() => _dropped.add(null);

  @override
  Future<void> leave() async {
    _hub._members.remove(this);
    _topic = null;
  }
}

CloudSignalingChannel _host(_FakeHub hub, {String code = 'AMP-ABCDEF'}) =>
    CloudSignalingChannel(
      code: code,
      role: SignalingRole.host,
      selfId: CloudSignalingChannel.hostId,
      sessionName: 'Party',
      transport: hub.transport(),
      iceBatchWindow: const Duration(milliseconds: 10),
    );

CloudSignalingChannel _listener(
  _FakeHub hub,
  String id, {
  String code = 'AMP-ABCDEF',
  BroadcastTransport? transport,
}) => CloudSignalingChannel(
  code: code,
  role: SignalingRole.listener,
  selfId: id,
  deviceName: 'Phone $id',
  transport: transport ?? hub.transport(),
  helloInterval: const Duration(milliseconds: 20),
  findHostTimeout: const Duration(milliseconds: 300),
  iceBatchWindow: const Duration(milliseconds: 10),
);

void main() {
  test('host connect resolves with a synthetic welcome', () async {
    final hub = _FakeHub();
    final host = _host(hub);
    final welcome = await host.connect();
    expect(welcome['type'], 'welcome');
    expect(welcome['sessionName'], 'Party');
    await host.close();
  });

  test('listener finds the host; host sees exactly one listener-joined',
      () async {
    final hub = _FakeHub();
    final host = _host(hub);
    await host.connect();
    final hostEvents = <Map<String, dynamic>>[];
    host.messages.listen(hostEvents.add);

    final listener = _listener(hub, 'L1');
    final welcome = await listener.connect();
    expect(welcome['type'], 'welcome');
    expect(welcome['sessionName'], 'Party');

    // Let any repeated hellos land; the host must not double-join.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final joins = hostEvents.where((m) => m['type'] == 'listener-joined');
    expect(joins, hasLength(1));
    expect(joins.single['id'], 'L1');
    expect(joins.single['deviceName'], 'Phone L1');

    await listener.close();
    await host.close();
  });

  test('listener joining a code with no host fails with a clear error',
      () async {
    final hub = _FakeHub();
    final listener = _listener(hub, 'L1', code: 'AMP-ZZZZZZ');
    await expectLater(
      listener.connect(),
      throwsA(
        isA<SignalingException>().having(
          (e) => e.message,
          'message',
          contains('Session not found'),
        ),
      ),
    );
  });

  test('an unreachable signaling service surfaces as SignalingException',
      () async {
    final hub = _FakeHub();
    final transport = hub.transport()..failJoin = true;
    final listener = _listener(hub, 'L1', transport: transport);
    await expectLater(listener.connect(), throwsA(isA<SignalingException>()));
  });

  test('offers/ICE reach only the addressed listener; answers reach the host',
      () async {
    final hub = _FakeHub();
    final host = _host(hub);
    await host.connect();
    final hostEvents = <Map<String, dynamic>>[];
    host.messages.listen(hostEvents.add);

    final a = _listener(hub, 'A');
    final b = _listener(hub, 'B');
    await a.connect();
    await b.connect();
    final aEvents = <Map<String, dynamic>>[];
    final bEvents = <Map<String, dynamic>>[];
    a.messages.listen(aEvents.add);
    b.messages.listen(bEvents.add);

    host.send({'type': 'offer', 'to': 'A', 'sdp': 'offer-for-A'});
    host.send({
      'type': 'ice',
      'to': 'A',
      'candidate': 'cand-1',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    });
    host.send({
      'type': 'ice',
      'to': 'A',
      'candidate': 'cand-2',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    });
    a.send({'type': 'answer', 'to': 'host', 'sdp': 'answer-from-A'});
    a.send({'type': 'ice', 'to': 'host', 'candidate': 'a-cand'});
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(aEvents.where((m) => m['type'] == 'offer').single['sdp'],
        'offer-for-A');
    expect(
      aEvents.where((m) => m['type'] == 'ice').map((m) => m['candidate']),
      ['cand-1', 'cand-2'],
    );
    expect(bEvents.where((m) => m['type'] == 'offer'), isEmpty);
    expect(bEvents.where((m) => m['type'] == 'ice'), isEmpty);

    final answer = hostEvents.singleWhere((m) => m['type'] == 'answer');
    expect(answer['from'], 'A');
    expect(answer['sdp'], 'answer-from-A');
    final ice = hostEvents.singleWhere((m) => m['type'] == 'ice');
    expect(ice['from'], 'A');
    expect(ice['candidate'], 'a-cand');

    // Trickled candidates were coalesced on the wire.
    final batches = hub.sent.where(
      (m) => m['type'] == 'ice-batch' && m['to'] == 'A',
    );
    expect(batches, hasLength(1));

    await a.close();
    await b.close();
    await host.close();
  });

  test('host end reaches every listener; listener close tells the host',
      () async {
    final hub = _FakeHub();
    final host = _host(hub);
    await host.connect();
    final hostEvents = <Map<String, dynamic>>[];
    host.messages.listen(hostEvents.add);

    final a = _listener(hub, 'A');
    final b = _listener(hub, 'B');
    await a.connect();
    await b.connect();
    final aEvents = <Map<String, dynamic>>[];
    a.messages.listen(aEvents.add);
    final bEvents = <Map<String, dynamic>>[];
    b.messages.listen(bEvents.add);

    await b.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      hostEvents.where((m) => m['type'] == 'listener-left').single['id'],
      'B',
    );

    host.send({'type': 'end'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(aEvents.where((m) => m['type'] == 'end'), hasLength(1));
    expect(bEvents.where((m) => m['type'] == 'end'), isEmpty); // already left

    await a.close();
    await host.close();
  });

  test('sessions with different codes are isolated', () async {
    final hub = _FakeHub();
    final host = _host(hub, code: 'AMP-AAAAAA');
    await host.connect();
    final listener = _listener(hub, 'L1', code: 'AMP-BBBBBB');
    await expectLater(listener.connect(), throwsA(isA<SignalingException>()));
    await host.close();
  });

  test('a dropped transport after connect is reported', () async {
    final hub = _FakeHub();
    final transport = hub.transport();
    final host = CloudSignalingChannel(
      code: 'AMP-ABCDEF',
      role: SignalingRole.host,
      selfId: CloudSignalingChannel.hostId,
      transport: transport,
    );
    await host.connect();
    final dropped = host.disconnected.first;
    transport.drop();
    await expectLater(dropped, completes);
    await host.close();
  });
}
