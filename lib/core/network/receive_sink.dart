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
  void add(Uint8List chunk);

  /// Bytes written so far.
  int get length;

  /// All chunks are in: flushes and returns the file.
  Future<ReceivedFile> finish();

  /// The transfer was cancelled or truncated: discard what was written.
  void abort();
}

typedef ReceiveSinkFactory = ReceiveSink Function({
  required String trackId,
  String? name,
  String? mime,
});

/// Keeps the file in memory (browsers, tests).
class MemoryReceiveSink implements ReceiveSink {
  MemoryReceiveSink({required this.trackId, String? name, this.mime});

  final String trackId;
  final String? mime;
  final BytesBuilder _buffer = BytesBuilder(copy: true);

  @override
  void add(Uint8List chunk) => _buffer.add(chunk);

  @override
  int get length => _buffer.length;

  @override
  Future<ReceivedFile> finish() async =>
      ReceivedFile(trackId: trackId, bytes: _buffer.takeBytes(), mime: mime);

  @override
  void abort() => _buffer.clear();
}
