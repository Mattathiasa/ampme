import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ampme/core/audio/growing_file_server.dart';
import 'package:ampme/core/network/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final file = Uint8List.fromList([for (var i = 0; i < 300000; i++) (i * 13 + i ~/ 97) & 0xff]);

  test('serves ranges, and a read past what has arrived waits for it', () async {
    final r = FileReceiver();
    r.handleText(FileTransferFrames.start(trackId: 'abc', size: file.length, mime: 'audio/wav', name: 'a.wav'));
    r.handleBinary(Uint8List.sublistView(file, 0, 100000));
    final growing = await r.waitForStart('abc');
    final server = GrowingFileServer(growing);
    final uri = await server.start();
    addTearDown(server.close);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    // The full size is announced up front; ranges work.
    final head = await (await client.openUrl('HEAD', uri)).close();
    expect(head.headers.contentLength, file.length);
    expect(head.headers.value('accept-ranges'), 'bytes');

    final part = await (await client.getUrl(uri)
          ..headers.set('range', 'bytes=1000-1999'))
        .close();
    expect(part.statusCode, 206);
    expect(part.headers.value('content-range'), 'bytes 1000-1999/${file.length}');
    expect(await part.fold<List<int>>([], (a, b) => a..addAll(b)), file.sublist(1000, 2000));

    // A request for bytes still on their way is answered once they land.
    // (The server answers once it has the first bytes, so don't await the
    // response itself before they land.)
    final body = client.getUrl(uri).then((req) {
      req.headers.set('range', 'bytes=150000-150999');
      return req.close();
    }).then((res) => res.fold<List<int>>([], (a, b) => a..addAll(b)));
    var finished = false;
    unawaited(body.then((_) => finished = true));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(finished, isFalse, reason: 'the bytes have not arrived');

    r.handleBinary(Uint8List.sublistView(file, 100000, 200000));
    expect(await body, file.sublist(150000, 151000));

    // The rest arrives; a request to the end gets it all.
    r.handleBinary(Uint8List.sublistView(file, 200000));
    r.handleText(FileTransferFrames.end('abc'));
    final tail = await (await client.getUrl(uri)
          ..headers.set('range', 'bytes=290000-'))
        .close();
    expect(await tail.fold<List<int>>([], (a, b) => a..addAll(b)), file.sublist(290000));

    final bad = await (await client.getUrl(uri)
          ..headers.set('range', 'bytes=999999-'))
        .close();
    expect(bad.statusCode, 416);
    await bad.drain<void>();
  });
}
