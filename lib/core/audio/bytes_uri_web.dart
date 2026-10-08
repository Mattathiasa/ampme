import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uri> bytesToUri(Uint8List bytes, {required String name, String? mime}) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mime ?? 'application/octet-stream'),
  );
  return Uri.parse(web.URL.createObjectURL(blob));
}

void releaseBytesUri(Uri uri) {
  if (uri.scheme != 'blob') return;
  web.URL.revokeObjectURL(uri.toString());
}
