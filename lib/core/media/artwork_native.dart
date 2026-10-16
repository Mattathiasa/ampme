import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The largest thumbnail sent to listeners (bytes, before base64).
const int maxArtworkBytes = 60 * 1024;

/// [cover] (JPEG or PNG, any size) as a small PNG, base64, ready for a
/// control message; null if it can't be read or won't get small enough.
Future<String?> shrinkArtwork(Uint8List cover) async {
  for (final width in const [200, 128, 80]) {
    try {
      final codec = await ui.instantiateImageCodec(cover, targetWidth: width);
      try {
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        frame.image.dispose();
        if (data == null) continue;
        final png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        if (png.length <= maxArtworkBytes) return base64Encode(png);
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null; // not an image this device can decode
    }
  }
  return null;
}
