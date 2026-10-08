import 'audio_engine.dart';
import 'just_audio_engine.dart';
import 'live_source.dart';
import 'live_wav_server.dart';
import 'pcm_ring.dart';

Future<LiveSource> openLiveSource(PcmRing ring, int epoch) async {
  final server = LiveWavServer(ring);
  final uri = await server.start();
  return _NativeLiveSource(uri, server);
}

AudioEngine createWebSessionEngine() => JustAudioEngine();

class _NativeLiveSource implements LiveSource {
  _NativeLiveSource(this.uri, this._server);

  @override
  final Uri uri;
  final LiveWavServer _server;

  @override
  Future<void> close() => _server.close();
}
