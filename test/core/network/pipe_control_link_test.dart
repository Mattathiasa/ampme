import 'dart:async';

import 'package:ampme/core/network/control_link.dart';
import 'package:ampme/core/network/models/control_message.dart';
import 'package:ampme/core/network/pipe_control_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<String> incoming;
  late List<ControlMessage> sent;
  late PipeControlLink link;

  setUp(() {
    incoming = StreamController<String>();
    sent = [];
    link = PipeControlLink(
      deviceId: 'phone',
      incoming: incoming.stream,
      sendFrame: (f) => sent.add(ControlMessage.decode(f)),
    );
  });

  tearDown(() => link.dispose());

  test('starts a clock-sync burst immediately', () {
    expect(sent.single.type, ControlMessageType.clockSyncRequest);
    expect(sent.single.senderId, 'phone');
  });

  test('clock-sync replies feed the estimator, not the message stream', () async {
    final messages = <ControlMessage>[];
    link.messages.listen(messages.add);
    final t0 = sent.single.payload['clientSendTimeMs'] as int;
    // Host clock 5 s ahead of ours.
    incoming.add(
      ControlMessage.clockSyncResponse(
        senderId: 'host',
        clientSendTimeMs: t0,
        hostTimeMs: DateTime.now().millisecondsSinceEpoch + 5000,
      ).encode(),
    );
    await pumpEventQueue();
    expect(messages, isEmpty);
    expect(link.syncSampleCount, 1);
    expect(link.clockEstimate!.offsetMs, closeTo(5000, 50));
    expect(link.isSyncFresh(), isTrue);
  });

  test('resetSync drops old samples and starts a new burst', () async {
    final t0 = sent.single.payload['clientSendTimeMs'] as int;
    incoming.add(
      ControlMessage.clockSyncResponse(senderId: 'host', clientSendTimeMs: t0, hostTimeMs: t0).encode(),
    );
    await pumpEventQueue();
    expect(link.syncSampleCount, 1);
    sent.clear();
    link.resetSync();
    expect(link.syncSampleCount, 0);
    expect(link.clockEstimate, isNull);
    expect(sent.single.type, ControlMessageType.clockSyncRequest);
  });

  test('forwards protocol messages and drops malformed frames', () async {
    final messages = <ControlMessage>[];
    link.messages.listen(messages.add);
    incoming
      ..add('not json')
      ..add(
        ControlMessage.prepare(senderId: 'host', trackId: 't', positionMs: 1200).encode(),
      );
    await pumpEventQueue();
    expect(messages.single.type, ControlMessageType.prepare);
  });

  test('reports reconnection and disconnection', () async {
    final statuses = <ReconnectionStatus>[];
    var disconnected = 0;
    link.reconnectionStatus.listen(statuses.add);
    link.disconnected.listen((_) => disconnected++);
    link.setReconnecting(true);
    link.setReconnecting(false);
    link.setReconnecting(true);
    link.close();
    await pumpEventQueue();
    expect(statuses, [
      ReconnectionStatus.attempting,
      ReconnectionStatus.succeeded,
      ReconnectionStatus.attempting,
      ReconnectionStatus.failed,
    ]);
    expect(disconnected, 1);
    sent.clear();
    link.send(ControlMessage.sessionEnded(senderId: 'phone'));
    expect(sent, isEmpty, reason: 'nothing is sent after close');
  });
}