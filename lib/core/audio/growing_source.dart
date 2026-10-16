import '../network/growing_file.dart';
import 'growing_source_native.dart' if (dart.library.js_interop) 'growing_source_web.dart' as impl;

/// A playable URI for a song that is still arriving ([GrowingFile]): a
/// loopback HTTP stream on native, a service-worker stream in the browser.
/// Null where that isn't available (a browser page without an active
/// service worker, e.g. plain HTTP): then wait for the whole file instead.
Future<GrowingSource?> openGrowingSource(GrowingFile file) => impl.openGrowingSource(file);

abstract class GrowingSource {
  Uri get uri;

  /// Stops serving and frees the song (its temp file, on native).
  Future<void> close();
}
