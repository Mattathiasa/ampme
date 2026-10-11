import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../network/models/playback_state.dart';
import 'audio_engine.dart';

/// [AudioEngine] for files in the browser, on a plain `<audio>` element.
///
/// Positions are read straight from the element's `currentTime` every time
/// they're needed. just_audio's web player only refreshes its position on
/// play/pause/seek, so after a start it extrapolated from the moment play()
/// was *called* — the browser's real start delay (tens of ms, up to ~0.1 s)
/// then sat in every reading, invisible: a listener could be 0.1 s behind
/// while measuring itself "in sync". `currentTime` is the element's own
/// audio clock, so that delay is visible and the drift loop removes it.
class HtmlAudioEngine implements AudioEngine {
  HtmlAudioEngine() {
    _el
      ..preload = 'auto'
      ..preservesPitch = true;
    void on(String type, void Function() handler) {
      _el.addEventListener(type, ((web.Event _) => handler()).toJS);
    }

    on('playing', () => _setState(PlaybackState.playing));
    on('pause', () => _setState(PlaybackState.paused));
    on('waiting', () {
      if (!_el.paused) _setState(PlaybackState.buffering);
    });
    on('ended', () => _setState(PlaybackState.stopped));
    on('error', () => _setState(PlaybackState.stopped));
  }

  final web.HTMLAudioElement _el = web.HTMLAudioElement();
  final _stateCtl = StreamController<PlaybackState>.broadcast();
  final _posCtl = StreamController<Duration>.broadcast();
  PlaybackState _state = PlaybackState.stopped;
  Timer? _scheduled;
  Timer? _posTimer;

  static const _haveFutureData = 3;

  void _setState(PlaybackState s) {
    if (s == _state) return;
    _state = s;
    _stateCtl.add(s);
  }

  /// Waits for [type] on the element, or [timeout]; true if it fired.
  Future<bool> _event(String type, Duration timeout) {
    final done = Completer<bool>();
    late final JSFunction listener;
    listener = ((web.Event _) {
      if (!done.isCompleted) done.complete(true);
    }).toJS;
    _el.addEventListener(type, listener);
    return done.future
        .timeout(timeout, onTimeout: () => false)
        .whenComplete(() => _el.removeEventListener(type, listener));
  }

  Duration _ms(num seconds) => Duration(microseconds: (seconds * 1e6).round());

  @override
  Future<Duration?> loadUrl(Uri uri, {required String title}) async {
    _scheduled?.cancel();
    _el.pause();
    _el.playbackRate = 1;
    final loaded = _event('loadedmetadata', const Duration(seconds: 15));
    _el.src = uri.toString();
    _el.load();
    _setState(PlaybackState.buffering);
    await loaded;
    _posTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      _posCtl.add(currentPosition);
    });
    _setState(PlaybackState.paused);
    return duration;
  }

  @override
  Future<Duration?> loadLocalFile(String path, {required String title}) =>
      loadUrl(Uri.parse(path), title: title);

  @override
  Future<void> play() async {
    try {
      await _el.play().toDart;
    } catch (_) {
      // Autoplay refused until the user taps; the page offers that.
    }
  }

  @override
  Future<void> pause() async {
    _scheduled?.cancel();
    _el.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    final seeked = _event('seeked', const Duration(seconds: 3));
    _el.currentTime = position.inMicroseconds / 1e6;
    await seeked;
  }

  Future<void> _waitUntilReady(Duration timeout) async {
    if (_el.readyState >= _haveFutureData || timeout <= Duration.zero) return;
    await _event('canplay', timeout);
  }

  @override
  Future<void> prepareForStart(Duration position) async {
    await pause();
    await seek(position);
    await _waitUntilReady(const Duration(seconds: 8));
  }

  @override
  Future<void> scheduleStart({required DateTime at, Duration position = Duration.zero}) async {
    await pause();
    final delay = at.difference(DateTime.now());
    if (!delay.isNegative) {
      await seek(position);
      await _waitUntilReady(delay);
      final remaining = at.difference(DateTime.now());
      if (!remaining.isNegative) {
        _scheduled = Timer(remaining, () => unawaited(play()));
        return;
      }
    }
    // The instant already passed (late join, slow load): catch up.
    await seek(position + DateTime.now().difference(at));
    await play();
  }

  @override
  Duration get currentPosition => _ms(_el.currentTime);

  @override
  Duration estimatePositionAt(DateTime t) {
    final now = DateTime.now();
    final pos = currentPosition;
    if (_el.paused || _el.readyState < _haveFutureData || !t.isAfter(now)) {
      return pos;
    }
    return pos + t.difference(now) * _el.playbackRate;
  }

  @override
  Future<void> setSpeed(double speed) async => _el.playbackRate = speed;

  @override
  Future<void> setVolume(double volume) async => _el.volume = volume.clamp(0.0, 1.0);

  @override
  Stream<Duration> get positionStream => _posCtl.stream;

  @override
  Stream<PlaybackState> get stateStream => _stateCtl.stream;

  @override
  Duration? get duration {
    final d = _el.duration;
    return d.isFinite ? _ms(d) : null;
  }

  @override
  Future<void> dispose() async {
    _scheduled?.cancel();
    _posTimer?.cancel();
    _el.pause();
    _el.removeAttribute('src');
    _el.load();
    await _stateCtl.close();
    await _posCtl.close();
  }
}
