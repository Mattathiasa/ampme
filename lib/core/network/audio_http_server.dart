import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';

/// An inclusive byte range resolved against a known total content length.
class RangeSpec {
  const RangeSpec({required this.start, required this.end});

  final int start;
  final int end;

  int get length => end - start + 1;
}

/// Thrown when a `Range` header is present but malformed or unsatisfiable
/// for the given content length (the server should reply 416 for these).
class RangeNotSatisfiableException implements Exception {
  const RangeNotSatisfiableException();
}

/// Parses an HTTP `Range` request header (single-range `bytes=` form only)
/// against a known [totalLength].
///
/// - Returns `null` when [headerValue] is absent: caller should serve the
///   full body with `200 OK`.
/// - Returns a resolved, clamped [RangeSpec] for a valid range: caller
///   should serve `206 Partial Content`.
/// - Throws [RangeNotSatisfiableException] for a malformed or out-of-bounds
///   range: caller should reply `416 Range Not Satisfiable`.
///
/// Pure function, deliberately kept free of `dart:io` types so it is
/// directly unit-testable without a running server.
RangeSpec? parseRangeHeader(String? headerValue, int totalLength) {
  if (headerValue == null) return null;
  if (totalLength <= 0) {
    throw const RangeNotSatisfiableException();
  }
  if (!headerValue.startsWith('bytes=')) {
    throw const RangeNotSatisfiableException();
  }

  final spec = headerValue.substring('bytes='.length).trim();
  if (spec.isEmpty || spec.contains(',')) {
    // Multi-range requests are not supported; reject rather than
    // silently serving only the first range.
    throw const RangeNotSatisfiableException();
  }

  final dashIndex = spec.indexOf('-');
  if (dashIndex == -1) {
    throw const RangeNotSatisfiableException();
  }

  final startPart = spec.substring(0, dashIndex);
  final endPart = spec.substring(dashIndex + 1);

  int start;
  int end;

  if (startPart.isEmpty) {
    // Suffix range: "bytes=-500" means the last 500 bytes.
    if (endPart.isEmpty) {
      throw const RangeNotSatisfiableException();
    }
    final suffixLength = int.tryParse(endPart);
    if (suffixLength == null || suffixLength <= 0) {
      throw const RangeNotSatisfiableException();
    }
    final clampedLength = suffixLength > totalLength ? totalLength : suffixLength;
    start = totalLength - clampedLength;
    end = totalLength - 1;
  } else {
    final parsedStart = int.tryParse(startPart);
    if (parsedStart == null || parsedStart < 0) {
      throw const RangeNotSatisfiableException();
    }
    start = parsedStart;

    if (endPart.isEmpty) {
      end = totalLength - 1;
    } else {
      final parsedEnd = int.tryParse(endPart);
      if (parsedEnd == null || parsedEnd < 0) {
        throw const RangeNotSatisfiableException();
      }
      end = parsedEnd;
    }
  }

  if (start > end || start >= totalLength) {
    throw const RangeNotSatisfiableException();
  }
  if (end >= totalLength) {
    end = totalLength - 1;
  }

  return RangeSpec(start: start, end: end);
}

/// Builds a 44-byte WAV/RIFF header for a **live** (unbounded) PCM stream.
///
/// The RIFF and `data` chunk sizes are set to `0xFFFFFFFF` — the standard
/// convention for a stream whose length isn't known up front — so a
/// listening player keeps reading until the connection closes instead of
/// stopping at a declared length.
Uint8List wavStreamHeader({
  required int sampleRate,
  required int channels,
  int bitsPerSample = 16,
}) {
  final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final bytes = BytesBuilder();

  void ascii(String s) => bytes.add(s.codeUnits);
  void u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    bytes.add(b.buffer.asUint8List());
  }

  void u16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    bytes.add(b.buffer.asUint8List());
  }

  ascii('RIFF');
  u32(0xFFFFFFFF); // chunk size — unknown/streaming
  ascii('WAVE');
  ascii('fmt ');
  u32(16); // PCM fmt chunk size
  u16(1); // audioFormat = PCM
  u16(channels);
  u32(sampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);
  ascii('data');
  u32(0xFFFFFFFF); // data size — unknown/streaming
  return bytes.toBytes();
}

/// Host-side HTTP server: serves the currently selected audio file's bytes
/// (with `Range` support so `just_audio`/ExoPlayer can seek and buffer on
/// listener devices), streams a live microphone/broadcast source at
/// `/live/<trackId>`, and hands off WebSocket upgrade requests on
/// `/control` to [onWebSocketConnected].
///
/// Owns a single [HttpServer] bound to an OS-assigned port so all routes
/// share one listening socket, avoiding a fixed-port collision risk.
class AudioHttpServer {
  HttpServer? _server;
  File? _currentFile;
  String? _currentTrackId;
  void Function(WebSocket socket)? onWebSocketConnected;

  // Live broadcast state (mic / captured audio). Null when not broadcasting.
  Stream<List<int>>? _livePcm;
  String? _liveTrackId;
  int _liveSampleRate = 44100;
  int _liveChannels = 1;

  int? get port => _server?.port;

  Future<int> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(_handleRequest);
    return server.port;
  }

  /// Sets the file currently served at `/stream/<trackId>`. Using the
  /// track id in the path (rather than a static path) forces the audio
  /// player to treat a new track as a fresh source instead of reusing
  /// cached range data from the previous one.
  void setCurrentTrack({required String trackId, required File file}) {
    _currentTrackId = trackId;
    _currentFile = file;
  }

  /// Points `/live/<trackId>` at a live PCM feed (e.g. the microphone). Each
  /// listener that connects gets a WAV header followed by the shared [pcm]
  /// broadcast stream.
  void setLiveSource({
    required String trackId,
    required Stream<List<int>> pcm,
    required int sampleRate,
    required int channels,
  }) {
    _liveTrackId = trackId;
    _livePcm = pcm;
    _liveSampleRate = sampleRate;
    _liveChannels = channels;
  }

  void clearLiveSource() {
    _liveTrackId = null;
    _livePcm = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request) &&
        request.uri.path == '/control') {
      final socket = await WebSocketTransformer.upgrade(request);
      onWebSocketConnected?.call(socket);
      return;
    }

    final segments = request.uri.pathSegments;
    if (request.method == 'GET' && segments.length == 2 && segments[0] == 'stream') {
      await _serveAudio(request, trackId: segments[1]);
      return;
    }
    if (request.method == 'GET' && segments.length == 2 && segments[0] == 'live') {
      await _serveLive(request, trackId: segments[1]);
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  /// Streams the live PCM source as an open-ended WAV response. Sends the
  /// header, then forwards mic chunks until either the source stops (host
  /// ends the broadcast) or the client disconnects.
  Future<void> _serveLive(HttpRequest request, {required String trackId}) async {
    final pcm = _livePcm;
    if (pcm == null || _liveTrackId != trackId) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'audio/wav')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache, no-store')
      // Length is unknown; Dart uses chunked transfer encoding, which
      // ExoPlayer/just_audio consume as a non-seekable live source.
      ..removeAll(HttpHeaders.contentLengthHeader);

    response.add(wavStreamHeader(
      sampleRate: _liveSampleRate,
      channels: _liveChannels,
    ));

    final completer = Completer<void>();
    final sub = pcm.listen(
      (chunk) {
        try {
          response.add(chunk);
        } catch (_) {
          // Client went away between chunks; unwind below.
          if (!completer.isCompleted) completer.complete();
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: false,
    );

    // Also unwind if the socket closes from the client side.
    unawaited(response.done.then(
      (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete();
      },
    ));

    await completer.future;
    await sub.cancel();
    try {
      await response.close();
    } catch (_) {
      // Socket already gone.
    }
  }

  Future<void> _serveAudio(HttpRequest request, {required String trackId}) async {
    final file = _currentFile;
    final currentTrackId = _currentTrackId;
    if (file == null || currentTrackId == null || currentTrackId != trackId) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final totalLength = await file.length();
    final contentType = lookupMimeType(file.path) ?? 'application/octet-stream';
    request.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, contentType);

    RangeSpec? range;
    try {
      range = parseRangeHeader(request.headers.value(HttpHeaders.rangeHeader), totalLength);
    } on RangeNotSatisfiableException {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalLength');
      await request.response.close();
      return;
    }

    if (range == null) {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.contentLengthHeader, totalLength);
      await request.response.addStream(file.openRead());
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers
      ..set(HttpHeaders.contentLengthHeader, range.length)
      ..set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/$totalLength',
      );
    await request.response.addStream(file.openRead(range.start, range.end + 1));
    await request.response.close();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _currentFile = null;
    _currentTrackId = null;
    clearLiveSource();
  }
}
