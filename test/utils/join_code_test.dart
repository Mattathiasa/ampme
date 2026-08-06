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
}
