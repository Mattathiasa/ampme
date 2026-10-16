import 'dart:io';
import 'dart:typed_data';

import 'package:ampme/core/media/tags.dart';
import 'package:flutter_test/flutter_test.dart';

/// The files in test/fixtures/tags were written by ffmpeg with the title
/// "Blinding Lights", the artist "The Weeknd" and a small JPEG cover.
Uint8List fixture(String name) => File('test/fixtures/tags/$name').readAsBytesSync();

bool isJpeg(Uint8List? b) => b != null && b.length > 3 && b[0] == 0xff && b[1] == 0xd8;

void main() {
  final cover = fixture('cover.jpg');

  for (final name in ['tagged.mp3', 'tagged.m4a', 'tagged.flac']) {
    test('$name: title, artist and the cover are read', () {
      final tags = readTags(fixture(name));
      expect(tags.title, 'Blinding Lights');
      expect(tags.artist, 'The Weeknd');
      expect(isJpeg(tags.artwork), isTrue);
      // The cover comes back byte for byte (ffmpeg copies it in untouched).
      expect(tags.artwork, cover);
    });
  }

  test('ID3v2.4 with accents and a dash (UTF-8) and no cover', () {
    final tags = readTags(fixture('plain_v24.mp3'));
    expect(tags.title, 'Café del Mar – Édition');
    expect(tags.artist, 'José González');
    expect(tags.artwork, isNull);
  });

  test('a file with no tags has none', () {
    expect(readTags(fixture('untagged.mp3')).isEmpty, isTrue);
  });

  test('something that is not music, or is cut short, has no tags and does not throw', () {
    expect(readTags(Uint8List(0)).isEmpty, isTrue);
    expect(readTags(Uint8List.fromList(List.filled(100, 7))).isEmpty, isTrue);
    for (final name in ['tagged.mp3', 'tagged.m4a', 'tagged.flac']) {
      final whole = fixture(name);
      for (final cut in [5, 12, 40, whole.length ~/ 2, whole.length - 3]) {
        // Whatever it finds, it must not throw.
        readTags(Uint8List.sublistView(whole, 0, cut));
      }
    }
  });

  test('a damaged tag header is survived', () {
    final b = Uint8List.fromList(fixture('tagged.mp3'));
    b.fillRange(10, 30, 0xff); // garbage where the first frame header is
    readTags(b);
  });

  test('ID3v2.2 (three-letter frames, UTF-16) is understood', () {
    // "ID3" 2.2, no flags, then TT2 "Hi" (UTF-16LE with a byte order mark)
    // and TP1 "Me" (Latin-1).
    final tt2Body = [1, 0xff, 0xfe, 0x48, 0x00, 0x69, 0x00]; // encoding 1
    final tp1Body = [0, 0x4d, 0x65];
    List<int> frame(String id, List<int> body) =>
        [...id.codeUnits, 0, 0, body.length, ...body];
    final frames = [...frame('TT2', tt2Body), ...frame('TP1', tp1Body)];
    final size = frames.length;
    final tag = [0x49, 0x44, 0x33, 2, 0, 0, 0, 0, (size >> 7) & 0x7f, size & 0x7f, ...frames];
    final tags = readTags(Uint8List.fromList(tag));
    expect(tags.title, 'Hi');
    expect(tags.artist, 'Me');
  });
}
