import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../network/growing_file.dart';
import 'growing_source.dart';

/// Songs the service worker (web/sw.js) may ask for, by track id.
final Map<String, GrowingFile> _served = {};
bool _listening = false;
Timer? _ping;

Future<GrowingSource?> openGrowingSource(GrowingFile file) async {
  final container = web.window.navigator.serviceWorker;
  if (!web.window.navigator.has('serviceWorker') || container.controller == null) {
    return null;
  }
  _served[file.trackId] = file;
  if (!_listening) {
    _listening = true;
    container.addEventListener('message', ((web.MessageEvent e) => unawaited(_answer(e))).toJS);
  }
  // A message now and then keeps the worker alive while a song streams.
  _ping ??= Timer.periodic(const Duration(seconds: 10), (_) {
    final c = web.window.navigator.serviceWorker.controller;
    if (c == null || _served.isEmpty) return;
    c.postMessage({'type': 'ampme-ping'}.jsify());
  });
  final uri = Uri.base.resolve('ampme-stream/${Uri.encodeComponent(file.trackId)}');
  return _WebGrowingSource(uri, file.trackId);
}

Future<void> _answer(web.MessageEvent event) async {
  final data = event.data;
  if (data == null || !data.isA<JSObject>()) return;
  final message = data as JSObject;
  final type = (message['type'] as JSString?)?.toDart;
  if (type != 'ampme-meta' && type != 'ampme-read') return;
  final id = message['id'];
  final trackId = (message['trackId'] as JSString?)?.toDart;
  final source = event.source;
  if (source == null || !source.isA<web.ServiceWorker>()) return;
  final worker = source as web.ServiceWorker;
  final reply = JSObject()
    ..['type'] = 'ampme-reply'.toJS
    ..['id'] = id;
  final file = trackId == null ? null : _served[trackId];
  if (file == null || file.failed) {
    reply['error'] = true.toJS;
  } else if (type == 'ampme-meta') {
    reply['size'] = file.size.toJS;
    reply['mime'] = (file.mime ?? 'application/octet-stream').toJS;
  } else {
    final start = (message['start'] as JSNumber).toDartInt;
    final end = (message['end'] as JSNumber).toDartInt;
    try {
      reply['bytes'] = (await file.read(start, end)).toJS;
    } catch (_) {
      reply['error'] = true.toJS;
    }
  }
  worker.postMessage(reply);
}

class _WebGrowingSource implements GrowingSource {
  _WebGrowingSource(this.uri, this._trackId);

  @override
  final Uri uri;
  final String _trackId;

  @override
  Future<void> close() async {
    _served.remove(_trackId);
    if (_served.isEmpty) {
      _ping?.cancel();
      _ping = null;
    }
  }
}
