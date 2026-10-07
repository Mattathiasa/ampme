import 'dart:js_interop';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:web/web.dart' as web;

import '../observability/reporting.dart';

/// Web: plays the remote WebRTC stream through a hidden `<audio>` element.
///
/// Browsers apply their autoplay policy to it: Chrome allows playback once
/// the user has interacted with the page (they clicked "Join"), but a session
/// joined straight from a link — or Safari — may refuse. In that case
/// [onBlocked] fires and the UI offers a "tap to start audio" button that
/// calls [resume] inside the tap handler.
class RemoteAudioSink {
  RemoteAudioSink({required this.onBlocked});

  final void Function() onBlocked;

  web.HTMLAudioElement? _element;
  double _volume = 1.0;
  bool _blocked = false;

  bool get isBlocked => _blocked;

  /// Nothing to configure in the browser.
  static Future<void> prepare() async {}

  Future<void> attach(rtc.MediaStream stream, rtc.MediaStreamTrack track) async {
    final jsStream = stream is MediaStreamWeb ? stream.jsStream : null;
    if (jsStream == null) return;
    final element = _element ??= _createElement();
    element.srcObject = jsStream;
    element.volume = _volume;
    await _play(element);
  }

  web.HTMLAudioElement _createElement() {
    final element = web.HTMLAudioElement()
      ..autoplay = true
      ..setAttribute('playsinline', 'true')
      ..style.display = 'none';
    web.document.body?.append(element);
    return element;
  }

  Future<void> _play(web.HTMLAudioElement element) async {
    try {
      await element.play().toDart;
      _blocked = false;
    } catch (e, st) {
      // NotAllowedError = autoplay policy; anything else is a real failure.
      _blocked = true;
      if (!e.toString().contains('NotAllowedError')) {
        reportError(e, st, context: 'remoteAudio.play');
      }
      onBlocked();
    }
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    _element?.volume = _volume;
  }

  /// Retries playback; call from a user gesture (tap) handler.
  Future<void> resume() async {
    final element = _element;
    if (element == null) return;
    await _play(element);
  }

  Future<void> dispose() async {
    final element = _element;
    _element = null;
    if (element == null) return;
    try {
      element.pause();
      element.srcObject = null;
      element.remove();
    } catch (_) {
      // Already detached.
    }
  }
}
