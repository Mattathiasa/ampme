import 'dart:io';
import 'dart:typed_data';

Future<Uri> bytesToUri(Uint8List bytes, {required String name, String? mime}) async {
  final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final dir = await Directory.systemTemp.createTemp('ampme_');
  final file = File('${dir.path}/$safe');
  await file.writeAsBytes(bytes, flush: true);
  return file.uri;
}

void releaseBytesUri(Uri uri) {
  if (uri.scheme != 'file') return;
  try {
    File.fromUri(uri).parent.deleteSync(recursive: true);
  } catch (_) {
    // Best effort; the OS clears its temp dir eventually.
  }
}
