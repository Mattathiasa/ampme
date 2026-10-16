import 'dart:io';
import 'dart:typed_data';

import 'receive_sink.dart';

/// Writes an incoming file straight to a fresh temp directory, so a large
/// video never has to fit in the app's memory. Writes are synchronous, so
/// every byte counted in [length] is already readable by the local stream
/// server while the rest is still arriving. `releaseBytesUri` deletes the
/// directory afterwards.
class FileReceiveSink implements ReceiveSink {
  FileReceiveSink({required this.trackId, String? name, this.mime, int size = 0}) {
    final safe = (name == null || name.isEmpty ? trackId : name)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    _dir = Directory.systemTemp.createTempSync('ampme_');
    _file = File('${_dir.path}/$safe');
    _out = _file.openSync(mode: FileMode.write);
  }

  final String trackId;
  final String? mime;
  late final Directory _dir;
  late final File _file;
  late final RandomAccessFile _out;
  RandomAccessFile? _reader;
  int _length = 0;
  int _end = 0; // highest position written
  bool _closed = false;

  File get file => _file;

  @override
  void writeAt(int offset, Uint8List chunk) {
    if (_closed) return;
    _out
      ..setPositionSync(offset)
      ..writeFromSync(chunk);
    _length += chunk.length;
    if (offset + chunk.length > _end) _end = offset + chunk.length;
  }

  @override
  int get length => _length;

  @override
  Future<Uint8List> read(int start, int end) async {
    end = end > _end ? _end : end;
    if (start >= end) return Uint8List(0);
    final reader = _reader ??= _file.openSync();
    reader.setPositionSync(start);
    return reader.readSync(end - start);
  }

  @override
  Future<ReceivedFile> finish() async {
    _closed = true;
    _out.closeSync();
    return ReceivedFile(trackId: trackId, uri: _file.uri, mime: mime);
  }

  @override
  void abort() {
    if (!_closed) {
      _closed = true;
      try {
        _out.closeSync();
      } catch (_) {}
    }
    try {
      _reader?.closeSync();
    } catch (_) {}
    _reader = null;
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
