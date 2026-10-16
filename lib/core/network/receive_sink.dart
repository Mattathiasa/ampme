import 'dart:typed_data';

/// A file received from the host: in memory ([bytes]) or already on disk
/// ([uri], a `file://` URI the player can open directly).
class ReceivedFile {
  const ReceivedFile({required this.trackId, this.bytes, this.uri, this.mime})
      : assert(bytes != null || uri != null);

  final String trackId;
  final Uint8List? bytes;
  final Uri? uri;
  final String? mime;
}

/// Where the chunks of one incoming file are written.
abstract class ReceiveSink {
  /// Writes [chunk] at file position [offset]. Chunks mostly arrive in
  /// order, but the end of the file may come first (see `FileReceiver`).
  void writeAt(int offset, Uint8List chunk);

  /// Bytes written so far.
  int get length;

  /// Bytes [start]..[end) — readable while the file is still arriving, so
  /// playback can start before it's whole. The caller makes sure they've
  /// arrived.
  Future<Uint8List> read(int start, int end);

  /// All chunks are in: flushes and returns the file.
  Future<ReceivedFile> finish();

  /// The transfer was cancelled or truncated: discard what was written.
  void abort();
}

typedef ReceiveSinkFactory = ReceiveSink Function({
  required String trackId,
  String? name,
  String? mime,
  int size,
});

/// Keeps the file in memory (browsers, tests).
class MemoryReceiveSink implements ReceiveSink {
  MemoryReceiveSink({required this.trackId, String? name, this.mime, int size = 0})
      : _buffer = Uint8List(size);

  final String trackId;
  final String? mime;
  Uint8List _buffer;
  int _length = 0;
  int _end = 0; // highest position written

  @override
  void writeAt(int offset, Uint8List chunk) {
    final end = offset + chunk.length;
    if (end > _buffer.length) {
      // Size unknown up front (tests): grow.
      final bigger = Uint8List(end > _buffer.length * 2 ? end : _buffer.length * 2);
      bigger.setRange(0, _buffer.length, _buffer);
      _buffer = bigger;
    }
    _buffer.setRange(offset, end, chunk);
    _length += chunk.length;
    if (end > _end) _end = end;
  }

  @override
  int get length => _length;

  @override
  Future<Uint8List> read(int start, int end) async {
    if (end > _end) end = _end;
    if (start >= end) return Uint8List(0);
    return Uint8List.fromList(Uint8List.sublistView(_buffer, start, end));
  }

  @override
  Future<ReceivedFile> finish() async => ReceivedFile(
        trackId: trackId,
        bytes: _end == _buffer.length ? _buffer : Uint8List.sublistView(_buffer, 0, _end),
        mime: mime,
      );

  @override
  void abort() {
    _buffer = Uint8List(0);
    _length = 0;
    _end = 0;
  }
}
