import 'dart:async';

import '../network/models/playback_state.dart';
import 'audio_engine.dart';

/// Routes each load to one of two engines — e.g. the regular file player and
/// a live-capture player in the browser — and exposes the active one, so a
/// session can move between songs and live audio with a single engine.
class SwitchingAudioEngine implements AudioEngine {
  SwitchingAudioEngine({
    required this.files,
    required this.live,
    required this.isLive,
  }) {
    _subs = [
      for (final e in [files, live]) ...[
        e.positionStream.listen((p) {
          if (identical(e, _active)) _pos.add(p);
        }),
        e.stateStream.listen((s) {
          if (identical(e, _active)) _state.add(s);
        }),
      ],
    ];
  }

  final AudioEngine files;
  final AudioEngine live;
  final bool Function(Uri uri) isLive;
  late AudioEngine _active = files;
  late final List<StreamSubscription<Object?>> _subs;
  final _pos = StreamController<Duration>.broadcast();
  final _state = StreamController<PlaybackState>.broadcast();

  @override
  Future<Duration?> loadUrl(Uri uri, {required String title}) async {
    final next = isLive(uri) ? live : files;
    if (!identical(next, _active)) {
      await _active.pause();
      _active = next;
    }
    return next.loadUrl(uri, title: title);
  }

  @override
  Future<Duration?> loadLocalFile(String path, {required String title}) async {
    if (!identical(_active, files)) {
      await _active.pause();
      _active = files;
    }
    return files.loadLocalFile(path, title: title);
  }

  @override
  Future<void> play() => _active.play();
  @override
  Future<void> pause() => _active.pause();
  @override
  Future<void> seek(Duration position) => _active.seek(position);
  @override
  Future<void> prepareForStart(Duration position) => _active.prepareForStart(position);
  @override
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero}) =>
      _active.scheduleStart(at: at, position: position);
  @override
  Duration get currentPosition => _active.currentPosition;
  @override
  Duration estimatePositionAt(DateTime t) => _active.estimatePositionAt(t);
  @override
  Future<void> setVolume(double volume) async {
    await files.setVolume(volume);
    await live.setVolume(volume);
  }

  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<PlaybackState> get stateStream => _state.stream;
  @override
  Duration? get duration => _active.duration;

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await files.dispose();
    await live.dispose();
    await _pos.close();
    await _state.close();
  }
}
