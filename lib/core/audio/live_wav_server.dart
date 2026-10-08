import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm_ring.dart';

/// Declared size of the endless WAV's data chunk: ~3 h of 48 kHz stereo.
/// Players treat the stream as a long, seekable file.
const int liveWavDataBytes = 0x7ff00000;

/// 44-byte header of the endless WAV the live stream is served as.
Uint8List liveWavHeader({required int sampleRate, required int channels}) {
  final h = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  h.setUint32(4, 36 + liveWavDataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  h
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * channels * 2, Endian.little)
    ..setUint16(32, channels * 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  h.setUint32(40, liveWavDataBytes, Endian.little);
  return h.buffer.asUint8List();
}

/// Serves a [PcmRing] as an endless WAV on the loopback interface, so the
/// regular audio player (ExoPlayer via just_audio) can play — and seek in —
/// the live capture with no special code: byte offset ↔ frame index is a
/// fixed mapping, reads past the live edge simply wait for the audio.
class LiveWavServer {
  LiveWavServer(this.ring);

  final PcmRing ring;
  HttpServer? _server;

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) => unawaited(_serve(request)));
    return Uri.parse('http://127.0.0.1:${server.port}/live.wav');
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      final header = liveWavHeader(sampleRate: ring.sampleRate, channels: ring.channels);
      final total = header.length + liveWavDataBytes;
      var start = 0;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final m = range == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (m != null) start = math.min(int.parse(m.group(1)!), total - 1);
      response.headers
        ..contentType = ContentType('audio', 'wav')
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..contentLength = total - start;
      if (m != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${total - 1}/$total');
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      if (start < header.length) {
        response.add(header.sublist(start));
        start = header.length;
      }
      final blockAlign = ring.channels * 2;
      var frame = (start - header.length) ~/ blockAlign;
      var skip = (start - header.length) % blockAlign; // mid-frame start
      const chunkFrames = 4096;
      final pcm = Int16List(chunkFrames * ring.channels);
      while (!ring.isClosed && _server != null) {
        await ring.waitFor(frame);
        if (ring.isClosed) break;
        final n = math.min(chunkFrames, ring.endFrame - frame);
        if (n <= 0) continue;
        final view = Int16List.sublistView(pcm, 0, n * ring.channels);
        ring.read(frame, view);
        final bytes = Uint8List.sublistView(view);
        response.add(skip > 0 ? Uint8List.fromList(bytes.sublist(skip)) : Uint8List.fromList(bytes));
        skip = 0;
        frame += n;
        await response.flush();
      }
    } catch (_) {
      // Player closed the connection (seek, stop): nothing to clean up.
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
