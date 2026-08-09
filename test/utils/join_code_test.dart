import 'package:ampme/utils/join_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseJoinCode', () {
    test('parses bare host:port', () {
      expect(
        parseJoinCode('192.168.1.5:54213'),
        const HostAddress(host: '192.168.1.5', port: 54213),
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        parseJoinCode('  10.0.0.2:8080  '),
        const HostAddress(host: '10.0.0.2', port: 8080),
      );
    });

    test('parses ampme:// deep link', () {
      expect(
        parseJoinCode('ampme://join?host=192.168.1.9&port=45454'),
        const HostAddress(host: '192.168.1.9', port: 45454),
      );
    });

    test('parses http:// url', () {
      expect(
        parseJoinCode('http://192.168.1.20:3000'),
        const HostAddress(host: '192.168.1.20', port: 3000),
      );
    });

    test('parses ws:// url', () {
      expect(
        parseJoinCode('ws://host.local:9000'),
        const HostAddress(host: 'host.local', port: 9000),
      );
    });

    test('rejects empty input', () {
      expect(parseJoinCode(''), isNull);
      expect(parseJoinCode('   '), isNull);
    });

    test('rejects missing port', () {
      expect(parseJoinCode('192.168.1.5'), isNull);
      expect(parseJoinCode('192.168.1.5:'), isNull);
    });

    test('rejects non-numeric port', () {
      expect(parseJoinCode('192.168.1.5:abc'), isNull);
    });

    test('rejects out-of-range port', () {
      expect(parseJoinCode('192.168.1.5:0'), isNull);
      expect(parseJoinCode('192.168.1.5:70000'), isNull);
    });

    test('rejects missing host', () {
      expect(parseJoinCode(':54213'), isNull);
    });
  });

  group('parseWebSessionCode', () {
    test('parses relay host:port/code', () {
      expect(
        parseWebSessionCode('192.168.1.10:8080/AMP-4821'),
        const WebSessionAddress(
          relayHost: '192.168.1.10',
          relayPort: 8080,
          code: 'AMP-4821',
        ),
      );
    });

    test('parses http:// and ws:// forms', () {
      expect(
        parseWebSessionCode('http://192.168.1.10:8080/AMP-4821'),
        const WebSessionAddress(
          relayHost: '192.168.1.10',
          relayPort: 8080,
          code: 'AMP-4821',
        ),
      );
      expect(
        parseWebSessionCode('ws://relay.local:9000/ABC123'),
        const WebSessionAddress(
          relayHost: 'relay.local',
          relayPort: 9000,
          code: 'ABC123',
        ),
      );
    });

    test('ignores extra path segments', () {
      expect(
        parseWebSessionCode('10.0.0.5:1234/AMP-9999/extra'),
        const WebSessionAddress(
          relayHost: '10.0.0.5',
          relayPort: 1234,
          code: 'AMP-9999',
        ),
      );
    });

    test('rejects codes without a token after the port', () {
      expect(parseWebSessionCode('192.168.1.10:8080'), isNull);
      expect(parseWebSessionCode('192.168.1.10:8080/'), isNull);
    });

    test('rejects missing/invalid port', () {
      expect(parseWebSessionCode('192.168.1.10/AMP-4821'), isNull);
      expect(parseWebSessionCode('192.168.1.10:0/AMP-4821'), isNull);
      expect(parseWebSessionCode('192.168.1.10:99999/AMP-4821'), isNull);
    });

    test('rejects empty input', () {
      expect(parseWebSessionCode(''), isNull);
      expect(parseWebSessionCode('   '), isNull);
    });
  });
}
