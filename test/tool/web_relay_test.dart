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
}
