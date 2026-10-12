import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../observability/reporting.dart';
import 'audio_route.dart';

const _channel = MethodChannel('com.ampme/audio_route');
StreamController<AudioRoute>? _changes;

Future<AudioRoute> currentAudioRoute() async {
  if (!Platform.isAndroid) return AudioRoute.fallback;
  try {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>('current');
    return map == null ? AudioRoute.fallback : AudioRoute.fromMap(map);
  } catch (e, st) {
    reportError(e, st, context: 'AudioRoutes.current');
    return AudioRoute.fallback;
  }
}

Stream<AudioRoute> audioRouteChanges() {
  if (!Platform.isAndroid) return const Stream.empty();
  return (_changes ??= _listen()).stream;
}

StreamController<AudioRoute> _listen() {
  late final StreamController<AudioRoute> controller;
  controller = StreamController<AudioRoute>.broadcast(
    onListen: () => unawaited(_channel.invokeMethod<void>('watch', true).catchError((Object _) {})),
    onCancel: () => unawaited(_channel.invokeMethod<void>('watch', false).catchError((Object _) {})),
  );
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'changed' && call.arguments is Map) {
      controller.add(AudioRoute.fromMap(call.arguments as Map<Object?, Object?>));
    }
  });
  return controller;
}
