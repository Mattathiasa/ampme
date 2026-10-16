import 'package:ampme/core/observability/diagnostics.dart';
import 'package:ampme/core/observability/scrub.dart';
import 'package:ampme/core/observability/sentry_scrub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('scrubSensitive', () {
    test('removes session codes and IPv4 addresses', () {
      expect(
        scrubSensitive('Joined AMP-8V4JVV at 192.168.1.5:8080 via amp-abcdef'),
        'Joined AMP-****** at x.x.x.x:8080 via AMP-******',
      );
    });

    test('leaves versions, clock times and ordinary words alone', () {
      const text = 'Ampme 1.9.0+14 at 12:03:08, sample 44100 Hz, camp-fire';
      expect(scrubSensitive(text), text);
    });
  });

  test('a Sentry event is scrubbed everywhere it can carry a code or an address', () {
    final event = SentryEvent(
      exceptions: [SentryException(type: 'SocketException', value: 'cannot reach 10.0.0.4:9000')],
      message: SentryMessage('joined AMP-ABCDEF', template: 'joined %s', params: ['AMP-ABCDEF', 7]),
      breadcrumbs: [Breadcrumb(message: 'ws://192.168.0.2/ws', data: {'code': 'AMP-ABCDEF', 'n': 3})],
      request: SentryRequest(url: 'https://x.example/web/?join=AMP-ABCDEF', queryString: 'join=AMP-ABCDEF'),
    );
    final json = scrubEvent(event).toJson().toString();
    expect(json, isNot(contains('ABCDEF')));
    expect(json, isNot(contains('10.0.0.4')));
    expect(json, isNot(contains('192.168.0.2')));
    expect(json, contains('x.x.x.x'));
    expect(json, contains('AMP-******'));
  });

  group('Diagnostics', () {
    setUp(Diagnostics.clear);

    test('a report holds the version, state, recent errors and sync readings, scrubbed', () {
      Diagnostics.error('joinSession', 'no route to 192.168.1.20 for AMP-QWERTY');
      Diagnostics.sync((
        at: DateTime(2026, 1, 1, 12, 0, 5),
        drift: -42,
        target: 5000,
        estimate: 4958,
        offset: -2990,
        rtt: 17,
        seekLead: 0,
        startLead: 60,
        nudge: 240,
        action: 'trim x1.021',
      ));
      final report = Diagnostics.format(
        version: '1.9.0+14',
        state: {'session': 'Party AMP-QWERTY on 192.168.1.20', 'output': 'JBL Flip 5'},
      );
      expect(report, contains('version: 1.9.0+14'));
      expect(report, contains('output: JBL Flip 5'));
      expect(report, contains('joinSession'));
      expect(report, contains('12:00:05  -42  5000  4958  -2990  17  0  60  240  trim x1.021'));
      expect(report, isNot(contains('QWERTY')));
      expect(report, isNot(contains('192.168.1.20')));
    });

    test('only the latest are kept', () {
      for (var i = 0; i < 400; i++) {
        Diagnostics.sync((
          at: DateTime(2026),
          drift: i,
          target: 0,
          estimate: 0,
          offset: 0,
          rtt: null,
          seekLead: 0,
          startLead: 0,
          nudge: 0,
          action: 'ok',
        ));
      }
      final report = Diagnostics.format(version: 'x');
      expect(report, contains('(240)'));
      expect(report, contains('  399  '));
      expect(report, isNot(contains('  100  0  0  0  -  ')), reason: 'old readings dropped');
    });
  });
}
