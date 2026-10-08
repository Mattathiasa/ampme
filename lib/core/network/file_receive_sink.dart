import 'dart:io';
import 'dart:typed_data';

import 'receive_sink.dart';

/// Writes an incoming file straight to a fresh temp directory, so a large
/// video never has to fit in the app's memory. The player opens the file
/// by its URI; `releaseBytesUri` deletes the directory afterwards.
class FileReceiveSink implements ReceiveSink {
  FileReceiveSink({required this.trackId, String? name, this.mime}) {
    final safe = (name == null || name.isEmpty ? trackId : name)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    _dir = Directory.systemTemp.createTempSync('ampme_');
    _file = File('${_dir.path}/$safe');
    _out = _file.openWrite();
  }

  final String trackId;
  final String? mime;
  late final Directory _dir;
  late final File _file;
  late final IOSink _out;
  int _length = 0;

  @override
  void add(Uint8List chunk) {
    _out.add(chunk);
    _length += chunk.length;
  }

  @override
  int get length => _length;

  @override
  Future<ReceivedFile> finish() async {
    await _out.flush();
    await _out.close();
    return ReceivedFile(trackId: trackId, uri: _file.uri, mime: mime);
  }

  @override
  void abort() {
    _out.close().whenComplete(() {
      try {
        _dir.deleteSync(recursive: true);
      } catch (_) {}
    }).ignore();
  }
}
