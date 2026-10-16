import 'dart:io';
import 'dart:typed_data';

import 'package:ampme/core/network/file_receive_sink.dart';
import 'package:ampme/core/network/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (i) => i % 251));

void main() {
  test('chunks cover the file exactly, in order', () {
    final bytes = _bytes(fileChunkSize * 2 + 123);
    final chunks = FileTransferFrames.chunks(bytes).toList();
    expect(chunks.map((c) => c.length), [fileChunkSize, fileChunkSize, 123]);
    expect(chunks.expand((c) => c).toList(), bytes);
    expect(FileTransferFrames.chunks(Uint8List(0)), isEmpty);
  });

  test('receiver reassembles a file and completes waiters', () async {
    final receiver = FileReceiver();
    final progress = <double>[];
    receiver.progress.listen(progress.add);
    final bytes = _bytes(40000);
    final waiting = receiver.waitFor('t1');

    receiver.handleText(FileTransferFrames.start(trackId: 't1', size: bytes.length, mime: 'audio/mpeg'));
    for (final c in FileTransferFrames.chunks(bytes)) {
      receiver.handleBinary(c);
    }
    receiver.handleText(FileTransferFrames.end('t1'));

    final file = await waiting;
    expect(file.bytes, bytes);
    expect(file.mime, 'audio/mpeg');
    await pumpEventQueue();
    expect(progress.last, 1.0);
    // Already received: resolves immediately.
    expect((await receiver.waitFor('t1')).bytes!.length, bytes.length);
    receiver.dispose();
  });

  test('a truncated transfer is not delivered; a newer song replaces it', () async {
    final receiver = FileReceiver();
    var delivered = false;
    receiver.waitFor('a').then((_) => delivered = true).ignore();
    receiver.handleText(FileTransferFrames.start(trackId: 'a', size: 100));
    receiver.handleBinary(_bytes(50));
    receiver.handleText(FileTransferFrames.end('a'));
    await pumpEventQueue();
    expect(delivered, isFalse);

    receiver.handleText(FileTransferFrames.start(trackId: 'b', size: 10));
    receiver.handleBinary(_bytes(10));
    receiver.handleText(FileTransferFrames.end('b'));
    expect((await receiver.waitFor('b')).bytes!.length, 10);
    receiver.dispose();
  });

  test('a file sink writes to disk and returns a file URI', () async {
    final receiver = FileReceiver(sinkFactory: FileReceiveSink.new);
    final bytes = _bytes(fileChunkSize * 3 + 7);
    receiver.handleText(FileTransferFrames.start(trackId: 'v', size: bytes.length, name: 'clip one.mp4'));
    for (final c in FileTransferFrames.chunks(bytes)) {
      receiver.handleBinary(c);
    }
    receiver.handleText(FileTransferFrames.end('v'));
    final file = await receiver.waitFor('v');
    expect(file.bytes, isNull);
    expect(file.uri!.pathSegments.last, 'clip_one.mp4');
    expect(await File.fromUri(file.uri!).readAsBytes(), bytes);
    File.fromUri(file.uri!).parent.deleteSync(recursive: true);
    receiver.dispose();
  });

  group('a host cannot make the listener over-commit', () {
    test('a song larger than the limit is refused, and its bytes ignored', () async {
      final receiver = FileReceiver(maxFileBytes: 1000);
      final waiting = receiver.waitFor('big');
      receiver.handleText(FileTransferFrames.start(trackId: 'big', size: 5000));
      receiver.handleBinary(_bytes(500)); // no transfer is open: dropped
      await expectLater(waiting, throwsA(isA<FileTransferException>()));
      expect(receiver.receivingTrackId, isNull);
      receiver.dispose();
    });

    test('a negative or missing size is refused', () async {
      final receiver = FileReceiver();
      final waiting = receiver.waitFor('x');
      receiver.handleText('{"type":"file-start","trackId":"x","size":-4}');
      await expectLater(waiting, throwsA(isA<FileTransferException>()));
      receiver.handleText('{"type":"file-start","trackId":"y"}');
      expect(receiver.receivingTrackId, isNull);
      receiver.dispose();
    });

    test('more bytes than announced abort the transfer instead of writing on', () async {
      final receiver = FileReceiver();
      final waiting = receiver.waitFor('o');
      receiver.handleText(FileTransferFrames.start(trackId: 'o', size: 100));
      receiver.handleBinary(_bytes(60));
      receiver.handleBinary(_bytes(60)); // 120 > 100
      await expectLater(waiting, throwsA(isA<FileTransferException>()));
      expect(receiver.receivingTrackId, isNull);
      receiver.dispose();
    });

    test('a sink that cannot be made leaves nothing half-started', () async {
      var calls = 0;
      final receiver = FileReceiver(sinkFactory: ({required trackId, name, mime, size = 0}) {
        if (calls++ == 0) throw const FileSystemException('disk full');
        return MemoryReceiveSink(trackId: trackId, size: size);
      });
      final waiting = receiver.waitFor('a');
      receiver.handleText(FileTransferFrames.start(trackId: 'a', size: 10));
      await expectLater(waiting, throwsA(isA<FileTransferException>()));
      expect(receiver.receivingTrackId, isNull);
      // The next song is received normally.
      receiver.handleText(FileTransferFrames.start(trackId: 'b', size: 10));
      receiver.handleBinary(_bytes(10));
      receiver.handleText(FileTransferFrames.end('b'));
      expect((await receiver.waitFor('b')).bytes!.length, 10);
      receiver.dispose();
    });

    test('a transfer that stops arriving is given up on', () async {
      final receiver = FileReceiver(stallTimeout: const Duration(milliseconds: 80));
      final waiting = receiver.waitFor('s');
      receiver.handleText(FileTransferFrames.start(trackId: 's', size: 100));
      receiver.handleBinary(_bytes(10));
      await expectLater(waiting, throwsA(isA<FileTransferException>()));
      expect(receiver.receivingTrackId, isNull);
      receiver.dispose();
    });

    test('a new song ends the wait for the old one; the same song keeps it', () async {
      final receiver = FileReceiver();
      final oldWait = receiver.waitFor('old');
      receiver.handleText(FileTransferFrames.start(trackId: 'old', size: 100));
      receiver.handleBinary(_bytes(10));
      // The host re-sends the same song (a reconnect): still waiting.
      receiver.handleText(FileTransferFrames.start(trackId: 'old', size: 100));
      var settled = false;
      oldWait.then((_) => settled = true, onError: (_) => settled = true).ignore();
      await pumpEventQueue();
      expect(settled, isFalse);
      // A different song supersedes it.
      receiver.handleText(FileTransferFrames.start(trackId: 'new', size: 10));
      await expectLater(oldWait, throwsA(isA<FileTransferException>()));
      receiver.dispose();
    });
  });

  test('a hostile file name stays a plain name inside its own temp folder', () async {
    for (final name in ['..', '.', '', '../../etc/passwd', 'a' * 400 + '.mp3']) {
      final sink = FileReceiveSink(trackId: 't', name: name);
      final file = (await (sink..writeAt(0, _bytes(4))).finish()).uri!;
      final path = file.toFilePath();
      final dir = File(path).parent;
      expect(dir.path, startsWith(Directory.systemTemp.path), reason: name);
      expect(path.split('/').last.length, lessThanOrEqualTo(100), reason: name);
      expect(File(path).existsSync(), isTrue, reason: name);
      dir.deleteSync(recursive: true);
    }
  });
}
