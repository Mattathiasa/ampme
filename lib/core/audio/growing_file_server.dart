import 'dart:async';
import 'dart:io';

import '../network/audio_http_server.dart' show RangeNotSatisfiableException, parseRangeHeader;
import '../network/growing_file.dart';

/// Serves a song that is still arriving on the loopback interface, so the
/// regular audio player (ExoPlayer via just_audio) can start on the first
/// seconds: the full size is announced up front, ranges work, and reads past
/// what has arrived simply wait for it — the same trick as `LiveWavServer`.
class GrowingFileServer {
  GrowingFileServer(this.file);

  final GrowingFile file;
  HttpServer? _server;

  static const int _block = 64 * 1024;

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) => unawaited(_serve(request)));
    final name = Uri.encodeComponent(file.name ?? 'song');
    return Uri.parse('http://127.0.0.1:${server.port}/${file.trackId}/$name');
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      final total = file.size;
      final mime = file.mime;
      if (mime != null) response.headers.contentType = ContentType.parse(mime);
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      var start = 0, end = total - 1;
      try {
        final range = parseRangeHeader(request.headers.value(HttpHeaders.rangeHeader), total);
        if (range != null) {
          start = range.start;
          end = range.end;
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
        }
      } on RangeNotSatisfiableException {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await response.close();
        return;
      }
      response.headers.contentLength = end - start + 1;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      var at = start;
      while (at <= end && _server != null) {
        final to = (at + _block > end + 1) ? end + 1 : at + _block;
        // Waits for bytes that haven't arrived yet.
        final bytes = await file.read(at, to);
        if (bytes.isEmpty) break;
        response.add(bytes);
        await response.flush();
        at += bytes.length;
      }
    } catch (_) {
      // The player closed the connection (seek, stop), or the transfer was
      // abandoned: nothing to clean up.
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }
}
