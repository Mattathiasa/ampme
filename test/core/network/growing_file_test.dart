import 'dart:typed_data';

import 'package:ampme/core/network/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 7 + i ~/ 251) & 0xff]);

/// A box header: size, type, then [payload] zeros.
Uint8List _box(String type, int payload) {
  final b = Uint8List(8 + payload);
  ByteData.sublistView(b).setUint32(0, b.length);
  b.setAll(4, type.codeUnits);
  return b;
}

Uint8List _cat(List<Uint8List> parts) => Uint8List.fromList([for (final p in parts) ...p]);

void main() {
  group('what has to arrive before playback starts', () {
    test('about 20 s of the song, never less than 256 KB, never more than the file', () {
      // 10 MB over 100 s: 20 s is 2 MB, plus 64 KB for headers.
      expect(
        progressiveStartBytes(size: 10 * 1024 * 1024, durationMs: 100000),
        10 * 1024 * 1024 ~/ 5 + 64 * 1024,
      );
      expect(progressiveStartBytes(size: 20 * 1024 * 1024, durationMs: 3600000), 256 * 1024);
      expect(progressiveStartBytes(size: 100 * 1024, durationMs: 100000), 100 * 1024);
      expect(progressiveStartBytes(size: 5000000, durationMs: 0), 5000000);
    });

    test('only formats that seek straight to a byte are streamed', () {
      expect(seeksDirectly('audio/wav'), isTrue);
      expect(seeksDirectly('audio/mp4'), isTrue);
      for (final m in ['audio/ogg', 'audio/mpeg', 'audio/flac', 'video/webm', null]) {
        expect(seeksDirectly(m), isFalse, reason: '$m');
      }
    });

    test('an MP4 qualifies when its index is in front, or was sent first', () {
      final indexFirst = _cat([_box('ftyp', 8), _box('moov', 200), _box('mdat', 5000)]);
      final dataFirst = _cat([_box('ftyp', 8), _box('mdat', 5000), _box('moov', 200)]);
      expect(isProgressivelyPlayable('audio/mp4', indexFirst), isTrue);
      expect(isProgressivelyPlayable('audio/mp4', dataFirst), isFalse);
      expect(isProgressivelyPlayable('audio/mp4', dataFirst, indexSentFirst: true), isTrue);
      expect(isProgressivelyPlayable('audio/wav', Uint8List(10)), isTrue);
      expect(isProgressivelyPlayable('application/octet-stream', Uint8List(10)), isFalse);
    });

    test('the part of a file sent ahead of its start', () {
      expect(tailFirstFrom(_bytes(500 * 1024), 'audio/mpeg'), 500 * 1024, reason: 'small: plain order');
      expect(tailFirstFrom(_bytes(3 * 1024 * 1024), 'audio/wav'), 3 * 1024 * 1024 - 64 * 1024);
      final ftyp = _box('ftyp', 8);
      final mdat = _box('mdat', 2 * 1024 * 1024);
      final mp4 = _cat([ftyp, mdat, _box('moov', 3000)]);
      expect(tailFirstFrom(mp4, 'audio/mp4'), ftyp.length + mdat.length, reason: 'from the index');
    });
  });

  group('receiving a song that is still arriving', () {
    Future<void> deliver(FileReceiver r, Uint8List file, {required int tailFrom, int chunk = 1000, double? stopAt}) async {
      r.handleText(FileTransferFrames.start(
        trackId: 't',
        size: file.length,
        mime: 'audio/wav',
        name: 'a.wav',
        tailFrom: tailFrom < file.length ? tailFrom : null,
      ));
      final order = [
        if (tailFrom < file.length) Uint8List.sublistView(file, tailFrom),
        Uint8List.sublistView(file, 0, tailFrom),
      ];
      var sent = 0;
      for (final chunkBytes in order.expand((p) => FileTransferFrames.chunks(p, chunk))) {
        if (stopAt != null && sent >= stopAt * file.length) return;
        r.handleBinary(chunkBytes);
        sent += chunkBytes.length;
      }
      r.handleText(FileTransferFrames.end('t'));
    }

    test('in order, the whole file comes out byte for byte', () async {
      final file = _bytes(25000);
      final r = FileReceiver();
      await deliver(r, file, tailFrom: file.length);
      expect((await r.waitFor('t')).bytes, file);
    });

    test('end first: reassembled in place, and readable while it arrives', () async {
      final file = _bytes(25003); // odd size: chunks straddle the tail boundary
      const tailFrom = 25003 - 6001;
      final r = FileReceiver();
      await deliver(r, file, tailFrom: tailFrom, chunk: 1000, stopAt: 0.5);
      final growing = await r.waitForStart('t');
      expect(growing.isComplete, isFalse);
      expect(growing.tailFrom, tailFrom);

      // The end was sent first, so it is there; the head is partly there.
      await growing.waitForRange(tailFrom, file.length);
      expect(await growing.read(tailFrom, file.length), file.sublist(tailFrom));
      expect(growing.received, greaterThan(0));
      expect(growing.received, lessThan(tailFrom));
      final have = growing.received;
      expect(await growing.read(0, have), file.sublist(0, have));

      // Bytes that haven't arrived wait for them.
      var done = false;
      final waiting = growing.read(tailFrom - 3000, tailFrom).then((b) {
        done = true;
        return b;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse);

      // The rest arrives.
      for (final c in FileTransferFrames.chunks(Uint8List.sublistView(file, 0, tailFrom), 1000).skip(have ~/ 1000)) {
        r.handleBinary(c);
      }
      r.handleText(FileTransferFrames.end('t'));
      expect(await waiting, file.sublist(tailFrom - 3000, tailFrom));
      expect((await r.waitFor('t')).bytes, file);
      expect(growing.isComplete, isTrue);
    });

    test('a new transfer abandons the old one: waiting readers fail, not hang', () async {
      final file = _bytes(10000);
      final r = FileReceiver();
      await deliver(r, file, tailFrom: file.length, stopAt: 0.3);
      final growing = await r.waitForStart('t');
      final waiting = growing.read(5000, 6000);
      r.handleText(FileTransferFrames.start(trackId: 'u', size: 10, mime: 'audio/wav'));
      await expectLater(waiting, throwsA(isA<FileTransferException>()));
      expect(growing.failed, isTrue);
    });
  });
}
