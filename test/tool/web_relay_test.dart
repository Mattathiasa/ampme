import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/web_relay.dart';

void main() {
  group('contentTypeFor', () {
    test('serves pages as text/html so browsers render them', () {
      expect(contentTypeFor('docs/index.html').mimeType, 'text/html');
      expect(contentTypeFor('build/web/index.html').mimeType, 'text/html');
    });

    test('uses the types browsers enforce for scripts, styles and wasm', () {
      expect(contentTypeFor('main.dart.js').mimeType, 'text/javascript');
      expect(contentTypeFor('style.css').mimeType, 'text/css');
      expect(contentTypeFor('canvaskit.wasm').mimeType, 'application/wasm');
      expect(contentTypeFor('manifest.json').mimeType, 'application/json');
    });

    test('images and fonts use their real top-level types', () {
      expect(contentTypeFor('icons/Icon-192.png').mimeType, 'image/png');
      expect(contentTypeFor('a.svg').mimeType, 'image/svg+xml');
      expect(contentTypeFor('MaterialIcons-Regular.otf').mimeType, 'font/otf');
    });

    test('unknown extensions fall back to octet-stream', () {
      expect(contentTypeFor('AssetManifest.bin').mimeType,
          ContentType.binary.mimeType);
      expect(contentTypeFor('NOTICES').mimeType, ContentType.binary.mimeType);
    });
  });

  group('isNoCachePath', () {
    test('entry points are revalidated', () {
      expect(isNoCachePath('build/web/index.html'), isTrue);
      expect(isNoCachePath('build/web/flutter_bootstrap.js'), isTrue);
    });

    test('heavy assets are cacheable', () {
      expect(isNoCachePath('build/web/main.dart.js'), isFalse);
      expect(isNoCachePath('build/web/canvaskit/canvaskit.wasm'), isFalse);
    });
  });

  group('isAllowedOrigin', () {
    test('native apps, the relay\'s own pages and local dev servers may connect', () {
      expect(isAllowedOrigin(null, '192.168.1.5'), isTrue);
      expect(isAllowedOrigin('http://192.168.1.5:8080', '192.168.1.5'), isTrue);
      expect(isAllowedOrigin('http://localhost:5000', '192.168.1.5'), isTrue);
      expect(isAllowedOrigin('http://127.0.0.1:8080', '192.168.1.5'), isTrue);
    });

    test('a page from anywhere else may not', () {
      expect(isAllowedOrigin('https://evil.example', '192.168.1.5'), isFalse);
      expect(isAllowedOrigin('http://192.168.1.99:8000', '192.168.1.5'), isFalse);
      expect(isAllowedOrigin('not a url', '192.168.1.5'), isFalse);
    });
  });

  group('SignalingRelay', () {
    late HttpServer server;
    final sockets = <WebSocket>[];

    setUp(() async {
      final relay = SignalingRelay();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        relay.handleClient(await WebSocketTransformer.upgrade(request));
      });
    });

    tearDown(() async {
      for (final s in sockets) {
        await s.close();
      }
      sockets.clear();
      await server.close(force: true);
    });

    /// A client with an inbox of everything it receives.
    Future<(WebSocket, List<Map<String, dynamic>>)> client() async {
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
      sockets.add(ws);
      final inbox = <Map<String, dynamic>>[];
      ws.listen((d) => inbox.add(jsonDecode(d as String) as Map<String, dynamic>), onError: (_) {});
      return (ws, inbox);
    }

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));
    void say(WebSocket ws, Map<String, dynamic> m) => ws.add(jsonEncode(m));

    test('a live code cannot be taken over by someone else, but its host can re-claim it', () async {
      final (host, hostInbox) = await client();
      say(host, {'type': 'host', 'code': 'AMP-1', 'sessionName': 'Party'});
      await settle();
      final token = hostInbox.single['hostToken'] as String;
      expect(token, isNotEmpty);

      final (thief, thiefInbox) = await client();
      say(thief, {'type': 'host', 'code': 'AMP-1', 'sessionName': 'Mine now'});
      await settle();
      expect(thiefInbox.single['type'], 'error');

      // The real session is untouched: a listener still finds its host.
      final (listener, listenerInbox) = await client();
      say(listener, {'type': 'listener', 'code': 'AMP-1', 'id': 'L1', 'deviceName': 'Phone'});
      await settle();
      expect(listenerInbox.single['sessionName'], 'Party');
      expect(hostInbox.last['type'], 'listener-joined');

      final (again, againInbox) = await client();
      say(again, {'type': 'host', 'code': 'AMP-1', 'sessionName': 'Party', 'hostToken': token});
      await settle();
      expect(againInbox.single['type'], 'welcome');
    });

    test('only the host can end a session', () async {
      final (host, hostInbox) = await client();
      say(host, {'type': 'host', 'code': 'AMP-2', 'sessionName': 'S'});
      final (listener, listenerInbox) = await client();
      await settle();
      say(listener, {'type': 'listener', 'code': 'AMP-2', 'id': 'L1'});
      await settle();

      say(listener, {'type': 'end'});
      await settle();
      expect(listenerInbox.where((m) => m['type'] == 'end'), isEmpty);
      expect(hostInbox.where((m) => m['type'] == 'end'), isEmpty);

      say(host, {'type': 'end'});
      await settle();
      expect(listenerInbox.last['type'], 'end');
    });

    test('the relay stamps who sent a message; a listener cannot pose as another', () async {
      final (host, hostInbox) = await client();
      say(host, {'type': 'host', 'code': 'AMP-3', 'sessionName': 'S'});
      final (a, _) = await client();
      final (b, bInbox) = await client();
      await settle();
      say(a, {'type': 'listener', 'code': 'AMP-3', 'id': 'A'});
      say(b, {'type': 'listener', 'code': 'AMP-3', 'id': 'B'});
      await settle();

      say(a, {'type': 'answer', 'to': 'host', 'from': 'B', 'sdp': 'x'});
      await settle();
      expect(hostInbox.last['type'], 'answer');
      expect(hostInbox.last['from'], 'A', reason: 'not the claimed B');

      // Only the host sends offers.
      say(a, {'type': 'offer', 'to': 'B', 'sdp': 'fake'});
      await settle();
      expect(bInbox.where((m) => m['type'] == 'offer'), isEmpty);
    });

    test('a client cannot reach into another session by naming its code', () async {
      final (hostA, hostAInbox) = await client();
      say(hostA, {'type': 'host', 'code': 'AMP-A', 'sessionName': 'A'});
      final (hostB, _) = await client();
      say(hostB, {'type': 'host', 'code': 'AMP-B', 'sessionName': 'B'});
      final (listenerB, _) = await client();
      await settle();
      say(listenerB, {'type': 'listener', 'code': 'AMP-B', 'id': 'LB'});
      await settle();

      say(listenerB, {'type': 'ice', 'to': 'host', 'code': 'AMP-A', 'candidate': 'c'});
      await settle();
      expect(hostAInbox.where((m) => m['type'] == 'ice'), isEmpty);
    });

    test('frames of the wrong shape or size do not take the relay down', () async {
      final (bad, _) = await client();
      for (final frame in [
        '{"type":"host","code":5}',
        '{"type":"listener","code":{},"id":[]}',
        '{"type":"offer","to":7}',
        '[1,2,3]',
        'not json',
        '{"type":"host","code":"${'x' * 200000}"}',
      ]) {
        bad.add(frame);
      }
      await settle();
      // A normal session still works afterwards.
      final (host, hostInbox) = await client();
      say(host, {'type': 'host', 'code': 'AMP-4', 'sessionName': 'S'});
      final (listener, listenerInbox) = await client();
      await settle();
      say(listener, {'type': 'listener', 'code': 'AMP-4', 'id': 'L'});
      await settle();
      expect(hostInbox.first['type'], 'welcome');
      expect(listenerInbox.first['type'], 'welcome');
    });
  });
}
