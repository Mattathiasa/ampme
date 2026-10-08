import 'audio_engine.dart';
import 'just_audio_engine.dart';
import 'live_source.dart';
import 'live_web_engine.dart';
import 'pcm_ring.dart';
import 'switching_audio_engine.dart';

Future<LiveSource> openLiveSource(PcmRing ring, int epoch) async {
  liveRings[epoch] = ring;
  return _WebLiveSource(epoch);
}

AudioEngine createWebSessionEngine() => SwitchingAudioEngine(
      files: JustAudioEngine(),
      live: LiveWebEngine(),
      isLive: LiveWebEngine.handles,
    );

class _WebLiveSource implements LiveSource {
  _WebLiveSource(this.epoch);

  final int epoch;

  @override
  Uri get uri => Uri(scheme: 'ampme-live', path: '$epoch');

  @override
  Future<void> close() async {
    liveRings.remove(epoch);
  }
}
