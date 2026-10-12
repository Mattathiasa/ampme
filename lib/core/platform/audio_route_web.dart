import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'audio_route.dart';

/// The browser's default output, by name. Names are only visible once the
/// page has had microphone access (calibration asks for it); until then
/// every output reads as the same "this browser" route.
Future<AudioRoute> currentAudioRoute() async {
  try {
    final media = web.window.navigator.mediaDevices;
    if (!web.window.navigator.has('mediaDevices')) return _browser;
    final devices = (await media.enumerateDevices().toDart).toDart;
    final outputs = devices.where((d) => d.kind == 'audiooutput').toList();
    if (outputs.isEmpty) return _browser;
    // Chrome lists the system default first, as "Default - <name>".
    final chosen = outputs.firstWhere((d) => d.deviceId == 'default', orElse: () => outputs.first);
    final label = chosen.label.replaceFirst(RegExp(r'^Default\s*-\s*'), '').trim();
    if (label.isEmpty) return _browser;
    return AudioRoute(
      'web:$label',
      label,
      isBluetooth: RegExp('bluetooth|airpods|buds|hands-free', caseSensitive: false).hasMatch(label),
    );
  } catch (_) {
    return _browser;
  }
}

const _browser = AudioRoute('web:default', 'This browser');

StreamController<AudioRoute>? _changes;

Stream<AudioRoute> audioRouteChanges() => (_changes ??= _watch()).stream;

StreamController<AudioRoute> _watch() {
  late final StreamController<AudioRoute> controller;
  JSFunction? listener;
  AudioRoute? last;
  controller = StreamController<AudioRoute>.broadcast(
    onListen: () async {
      if (!web.window.navigator.has('mediaDevices')) return;
      last = await currentAudioRoute();
      Future<void> check() async {
        final now = await currentAudioRoute();
        if (now != last && !controller.isClosed) {
          last = now;
          controller.add(now);
        }
      }

      listener = ((web.Event _) => unawaited(check())).toJS;
      web.window.navigator.mediaDevices.addEventListener('devicechange', listener);
    },
    onCancel: () {
      final l = listener;
      listener = null;
      if (l != null) web.window.navigator.mediaDevices.removeEventListener('devicechange', l);
    },
  );
  return controller;
}
