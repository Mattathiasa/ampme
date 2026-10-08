import 'dart:typed_data';

import 'bytes_uri_native.dart' if (dart.library.js_interop) 'bytes_uri_web.dart'
    as impl;

/// Makes received song bytes playable by URI: a temp file on native, a
/// `blob:` URL in the browser. Release it with [releaseBytesUri] when the
/// song is replaced.
Future<Uri> bytesToUri(Uint8List bytes, {required String name, String? mime}) =>
    impl.bytesToUri(bytes, name: name, mime: mime);

void releaseBytesUri(Uri uri) => impl.releaseBytesUri(uri);
