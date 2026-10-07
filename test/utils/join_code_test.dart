import 'dart:math';

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

  group('generateCloudSessionCode', () {
    test('produces AMP- plus six unambiguous characters', () {
      final rng = Random(42);
      for (var i = 0; i < 200; i++) {
        final code = generateCloudSessionCode(rng);
        expect(code, matches(RegExp(r'^AMP-[A-Z0-9]{6}$')));
        expect(code.substring(4), isNot(matches(RegExp('[01OIL]'))));
      }
    });

    test('round-trips through parseCloudSessionCode', () {
      final code = generateCloudSessionCode(Random(7));
      expect(parseCloudSessionCode(code), code);
    });
  });

  group('parseCloudSessionCode', () {
    test('parses a bare code, case-insensitively', () {
      expect(parseCloudSessionCode('AMP-7KQ4ZD'), 'AMP-7KQ4ZD');
      expect(parseCloudSessionCode('  amp-7kq4zd '), 'AMP-7KQ4ZD');
    });

    test('accepts the code without its dash', () {
      expect(parseCloudSessionCode('AMP7KQ4ZD'), 'AMP-7KQ4ZD');
    });

    test('parses a join link', () {
      expect(
        parseCloudSessionCode(
          'https://mattathiasa.github.io/ampme/web/?join=AMP-7KQ4ZD',
        ),
        'AMP-7KQ4ZD',
      );
      expect(
        parseCloudSessionCode('http://localhost:5000/?join=amp-7kq4zd#/'),
        'AMP-7KQ4ZD',
      );
    });

    test('does not match LAN relay or native codes', () {
      expect(parseCloudSessionCode('192.168.1.10:8080/AMP-7KQ4ZD'), isNull);
      expect(parseCloudSessionCode('192.168.1.5:54213'), isNull);
      expect(parseCloudSessionCode('ampme://join?host=10.0.0.2&port=80'), isNull);
    });

    test('rejects wrong lengths and junk', () {
      expect(parseCloudSessionCode('AMP-4821'), isNull);
      expect(parseCloudSessionCode('AMP-7KQ4ZDX'), isNull);
      expect(parseCloudSessionCode('AMPLIFY'), isNull);
      expect(parseCloudSessionCode(''), isNull);
      expect(parseCloudSessionCode('https://example.com/?join='), isNull);
    });
  });

  group('buildJoinLink', () {
    test('uses the page URL when other devices can open it', () {
      expect(
        buildJoinLink(
          Uri.parse('https://mattathiasa.github.io/ampme/web/#/'),
          'AMP-7KQ4ZD',
        ),
        'https://mattathiasa.github.io/ampme/web/?join=AMP-7KQ4ZD',
      );
      expect(
        buildJoinLink(Uri.parse('http://192.168.1.10:8080/web/'), 'AMP-7KQ4ZD'),
        'http://192.168.1.10:8080/web/?join=AMP-7KQ4ZD',
      );
    });

    test('falls back to the public web app for loopback pages', () {
      expect(
        buildJoinLink(Uri.parse('http://localhost:53127/'), 'AMP-7KQ4ZD'),
        '$publicWebAppUrl?join=AMP-7KQ4ZD',
      );
      expect(
        buildJoinLink(Uri.parse('http://127.0.0.1:8080/web/'), 'AMP-7KQ4ZD'),
        '$publicWebAppUrl?join=AMP-7KQ4ZD',
      );
    });

    test('the link parses back to the code', () {
      final link = buildJoinLink(Uri.parse('http://localhost:1/'), 'AMP-ABCDEF');
      expect(parseCloudSessionCode(link), 'AMP-ABCDEF');
    });
  });
}
