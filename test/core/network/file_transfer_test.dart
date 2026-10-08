import 'dart:typed_data';

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
    expect((await receiver.waitFor('t1')).bytes.length, bytes.length);
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
    expect((await receiver.waitFor('b')).bytes.length, 10);
    receiver.dispose();
  });
}
