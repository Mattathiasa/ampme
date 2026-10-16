import '../network/growing_file.dart';
import 'growing_file_server.dart';
import 'growing_source.dart';

Future<GrowingSource?> openGrowingSource(GrowingFile file) async {
  final server = GrowingFileServer(file);
  return _NativeGrowingSource(await server.start(), server, file);
}

class _NativeGrowingSource implements GrowingSource {
  _NativeGrowingSource(this.uri, this._server, this._file);

  @override
  final Uri uri;
  final GrowingFileServer _server;
  final GrowingFile _file;

  @override
  Future<void> close() async {
    await _server.close();
    _file.sink.abort(); // deletes the temp file
  }
}
