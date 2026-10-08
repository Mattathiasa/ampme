import 'package:ampme/features/host/sync_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('start lead covers the slowest round trip, within bounds', () {
    expect(startLeadMs(const []), minStartLeadMs);
    expect(startLeadMs(const [20, 60]), minStartLeadMs);
    expect(startLeadMs(const [40, 450]), 450 + startLeadMarginMs);
    expect(startLeadMs(const [9000]), 3000);
  });

  test('drift compares against the host timeline when the report was sent', () {
    // Host timeline: position == wall time - 1000.
    int host(int wall) => wall - 1000;
    // Listener reported 9000 at host wall 10000 (received at 10100, RTT 200).
    expect(
      listenerDriftMs(
        listenerPositionMs: 9000,
        roundTripMs: 200,
        receivedAtMs: 10100,
        hostPositionAt: host,
      ),
      0,
    );
    expect(
      listenerDriftMs(
        listenerPositionMs: 9030,
        roundTripMs: 200,
        receivedAtMs: 10100,
        hostPositionAt: host,
      ),
      30,
    );
  });

  test('audio MIME types by extension', () {
    expect(audioMimeFor('song.MP3'), 'audio/mpeg');
    expect(audioMimeFor('a.b.m4a'), 'audio/mp4');
    expect(audioMimeFor('noext'), isNull);
    expect(audioMimeFor('x.xyz'), isNull);
  });
}
