import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// The largest thumbnail sent to listeners (bytes, before base64).
const int maxArtworkBytes = 60 * 1024;

/// [cover] (JPEG or PNG, any size) as a small JPEG, base64, ready for a
/// control message; null if the browser can't read it.
Future<String?> shrinkArtwork(Uint8List cover) async {
  try {
    final isPng = cover.length > 4 && cover[0] == 0x89 && cover[1] == 0x50;
    final blob = web.Blob([cover.toJS].toJS, web.BlobPropertyBag(type: isPng ? 'image/png' : 'image/jpeg'));
    final bitmap = await web.window.createImageBitmap(blob).toDart;
    for (final side in const [200, 128, 80]) {
      final scale = math.min(1.0, side / math.max(bitmap.width, bitmap.height));
      final w = math.max(1, (bitmap.width * scale).round());
      final h = math.max(1, (bitmap.height * scale).round());
      final canvas = web.HTMLCanvasElement()
        ..width = w
        ..height = h;
      final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
      ctx.drawImage(bitmap, 0, 0, w.toDouble(), h.toDouble());
      final done = Completer<web.Blob?>();
      canvas.toBlob(((web.Blob? b) => done.complete(b)).toJS, 'image/jpeg', 0.82.toJS);
      final out = await done.future;
      if (out == null) continue;
      final bytes = (await out.arrayBuffer().toDart).toDart.asUint8List();
      if (bytes.length <= maxArtworkBytes) {
        bitmap.close();
        return base64Encode(bytes);
      }
    }
    bitmap.close();
  } catch (_) {
    // Not an image this browser can decode.
  }
  return null;
}
