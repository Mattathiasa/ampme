import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'receive_sink.dart';

export 'receive_sink.dart' show ReceiveSink, ReceiveSinkFactory, ReceivedFile, MemoryReceiveSink;

/// Size of each binary data-channel message carrying song bytes. 16 KiB is
/// the largest size every WebRTC stack (Chrome, Firefox, Safari, libwebrtc
/// on Android) delivers without fragmentation trouble.
const int fileChunkSize = 16 * 1024;

/// Wire format for sending a song over a data channel, host -> listener:
///
///   text   {"type":"file-start","trackId":…,"size":N,"mime":…,"name":…}
///   binary chunk, chunk, … (exactly N bytes in total, in order)
///   text   {"type":"file-end","trackId":…}
///
/// The channel is reliable and ordered, so no sequence numbers are needed.
abstract final class FileTransferFrames {
  static String start({
    required String trackId,
    required int size,
    String? mime,
    String? name,
  }) =>
      jsonEncode({
        'type': 'file-start',
        'trackId': trackId,
        'size': size,
        'mime': ?mime,
        'name': ?name,
      });

  static String end(String trackId) => jsonEncode({'type': 'file-end', 'trackId': trackId});

  /// Splits [bytes] into [fileChunkSize] views (no copying).
  static Iterable<Uint8List> chunks(Uint8List bytes, [int size = fileChunkSize]) sync* {
    for (var offset = 0; offset < bytes.length; offset += size) {
      final end = offset + size < bytes.length ? offset + size : bytes.length;
      yield Uint8List.sublistView(bytes, offset, end);
    }
  }
}

/// Listener side: reassembles files from [FileTransferFrames] and hands them
/// to whoever is waiting for that track. Where the bytes go is up to
/// [sinkFactory]: memory by default, a temp file on Android (so a large video
/// never sits in RAM).
class FileReceiver {
  FileReceiver({ReceiveSinkFactory? sinkFactory})
      : _sinkFactory = sinkFactory ?? MemoryReceiveSink.new;

  final ReceiveSinkFactory _sinkFactory;
  String? _trackId;
  int _expected = 0;
  ReceiveSink? _sink;

  final Map<String, ReceivedFile> _done = {};
  final Map<String, Completer<ReceivedFile>> _waiters = {};
  final _progress = StreamController<double>.broadcast();

  /// Fraction (0..1) of the file currently being received.
  Stream<double> get progress => _progress.stream;

  /// The track currently being received, if any.
  String? get receivingTrackId => _trackId;

  void handleText(String frame) {
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    switch (decoded['type']) {
      case 'file-start':
        final id = decoded['trackId'] as String?;
        if (id == null) return;
        _sink?.abort(); // an unfinished earlier transfer is superseded
        _trackId = id;
        _expected = (decoded['size'] as num?)?.toInt() ?? 0;
        _sink = _sinkFactory(
          trackId: id,
          name: decoded['name'] as String?,
          mime: decoded['mime'] as String?,
        );
        _emitProgress();
      case 'file-end':
        final id = _trackId;
        final sink = _sink;
        _trackId = null;
        _sink = null;
        if (id == null || sink == null || decoded['trackId'] != id) {
          sink?.abort();
          return;
        }
        if (sink.length != _expected) {
          sink.abort(); // truncated — the host resends on reconnect
          return;
        }
        unawaited(_finish(id, sink));
    }
  }

  Future<void> _finish(String id, ReceiveSink sink) async {
    final ReceivedFile file;
    try {
      file = await sink.finish();
    } catch (e) {
      _waiters.remove(id)?.completeError(e);
      return;
    }
    // Only the newest song is kept: a session plays one at a time.
    _done
      ..clear()
      ..[id] = file;
    _waiters.remove(id)?.complete(file);
  }

  void handleBinary(Uint8List chunk) {
    final sink = _sink;
    if (sink == null) return;
    sink.add(chunk);
    _emitProgress();
  }

  void _emitProgress() {
    if (_progress.isClosed || _expected <= 0) return;
    _progress.add(((_sink?.length ?? 0) / _expected).clamp(0.0, 1.0));
  }

  /// The bytes of [trackId] once fully received (immediately if they are).
  Future<ReceivedFile> waitFor(String trackId) {
    final done = _done[trackId];
    if (done != null) return Future.value(done);
    return (_waiters[trackId] ??= Completer<ReceivedFile>()).future;
  }

  void dispose() {
    _sink?.abort();
    _sink = null;
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.completeError(StateError('Session closed'));
    }
    _waiters.clear();
    _done.clear();
    unawaited(_progress.close());
  }
}
