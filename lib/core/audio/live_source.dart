import 'audio_engine.dart';
import 'live_source_native.dart' if (dart.library.js_interop) 'live_source_web.dart' as impl;
import 'pcm_ring.dart';

/// A playable URI for a live capture's [ring]: an endless WAV on a loopback
/// HTTP server (native — the regular player streams it) or an
/// `ampme-live:` URI the browser's live engine resolves.
Future<LiveSource> openLiveSource(PcmRing ring, int epoch) => impl.openLiveSource(ring, epoch);

/// The audio engine a browser-hosted session's listener uses: the file
/// player, plus the live player in the browser.
AudioEngine createWebSessionEngine() => impl.createWebSessionEngine();

abstract class LiveSource {
  Uri get uri;
  Future<void> close();
}
