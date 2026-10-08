import 'package:ampme/core/network/webrtc/playout_latency.dart';
import 'package:flutter_test/flutter_test.dart';

({String type, Map<dynamic, dynamic> values}) inbound(Object delay, Object count) =>
    (type: 'inbound-rtp', values: {'kind': 'audio', 'jitterBufferDelay': delay, 'jitterBufferEmittedCount': count});

({String type, Map<dynamic, dynamic> values}) pair(Object rtt, {Object nominated = true, String state = 'succeeded'}) =>
    (type: 'candidate-pair', values: {'state': state, 'nominated': nominated, 'currentRoundTripTime': rtt});

void main() {
  test('first sample: lifetime jitter average + half RTT + one frame', () {
    // 9600 s of summed per-sample delay over 48000 samples = 200 ms; RTT 60 ms -> 30.
    final m = PlayoutLatencyMeter();
    expect(m.update([inbound(9600, 48000), pair(0.06)]), 200 + 30 + 20);
  });

  test('later samples use the delta over the interval', () {
    final m = PlayoutLatencyMeter();
    m.update([inbound(9600, 48000), pair(0.0)]); // 200 ms average so far
    // Next second: +48000 samples at 500 ms each -> +24000 s summed.
    expect(m.update([inbound(33600, 96000), pair(0.0)]), 500 + 20);
  });

  test('parses Android-style string values', () {
    final m = PlayoutLatencyMeter();
    expect(m.update([inbound('4800', '48000'), pair('0.1', nominated: 'true')]), 100 + 50 + 20);
  });

  test('ignores pairs that are not the selected route', () {
    final m = PlayoutLatencyMeter();
    expect(
      m.update([inbound(4800, 48000), pair(2.0, nominated: false), pair(2.0, state: 'failed')]),
      100 + 20,
    );
  });

  test('no inbound audio yet -> null', () {
    final m = PlayoutLatencyMeter();
    expect(m.update([pair(0.05)]), isNull);
    expect(m.update([inbound(0, 0)]), isNull);
  });

  test('counter reset falls back to the lifetime average', () {
    final m = PlayoutLatencyMeter();
    m.update([inbound(9600, 48000)]);
    expect(m.update([inbound(1200, 12000)]), 100 + 20);
  });

  test('smoothLatency moves 30% toward each new sample', () {
    expect(smoothLatency(null, 400), 400);
    expect(smoothLatency(200, 400), 260);
  });
}
