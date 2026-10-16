import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'growing_file.dart';
import 'receive_sink.dart';

export 'growing_file.dart';
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
  /// [tailFrom]: bytes tailFrom..size come first, then 0..tailFrom (only
  /// for listeners that announced [tailFirstFeature]).
  static String start({
    required String trackId,
    required int size,
    String? mime,
    String? name,
    int? tailFrom,
  }) =>
      jsonEncode({
        'type': 'file-start',
        'trackId': trackId,
        'size': size,
        'mime': ?mime,
        'name': ?name,
        'tailFrom': ?tailFrom,
      });

  /// Feature a listener announces (in its hello) when it can take a file
  /// whose end is sent first. Older listeners append every chunk in order.
  static const tailFirstFeature = 'tail-first';

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
  int _tailFrom = 0;
  ReceiveSink? _sink;
  GrowingFile? _growing;

  /// The newest song's bytes as they arrive (kept after it completes, while
  /// it's the session's song).
  final Map<String, GrowingFile> _growingFiles = {};
  final Map<String, Completer<GrowingFile>> _startWaiters = {};

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
        _abortCurrent(); // an unfinished earlier transfer is superseded
        _trackId = id;
        _expected = (decoded['size'] as num?)?.toInt() ?? 0;
        final tailFrom = (decoded['tailFrom'] as num?)?.toInt();
        _tailFrom = tailFrom == null || tailFrom < 0 || tailFrom > _expected ? _expected : tailFrom;
        final sink = _sink = _sinkFactory(
          trackId: id,
          name: decoded['name'] as String?,
          mime: decoded['mime'] as String?,
          size: _expected,
        );
        final growing = _growing = GrowingFile(
          trackId: id,
          size: _expected,
          sink: sink,
          tailFrom: _tailFrom,
          mime: decoded['mime'] as String?,
          name: decoded['name'] as String?,
        );
        // One song at a time: an older growing file is no longer served.
        _growingFiles
          ..clear()
          ..[id] = growing;
        _startWaiters.remove(id)?.complete(growing);
        _emitProgress();
      case 'file-end':
        final id = _trackId;
        final sink = _sink;
        final growing = _growing;
        if (id == null || sink == null || decoded['trackId'] != id) {
          _abortCurrent();
          return;
        }
        if (sink.length != _expected) {
          _abortCurrent(); // truncated — the host resends on reconnect
          return;
        }
        _trackId = null;
        _sink = null;
        _growing = null;
        unawaited(_finish(id, sink, growing));
    }
  }

  void _abortCurrent() {
    final id = _trackId;
    _growing?.fail(StateError('Transfer abandoned'));
    if (id != null) _growingFiles.remove(id);
    _sink?.abort();
    _trackId = null;
    _sink = null;
    _growing = null;
  }

  Future<void> _finish(String id, ReceiveSink sink, GrowingFile? growing) async {
    final ReceivedFile file;
    try {
      file = await sink.finish();
    } catch (e) {
      growing?.fail(e);
      _waiters.remove(id)?.completeError(e);
      return;
    }
    growing?.completed();
    // Only the newest song is kept: a session plays one at a time.
    _done
      ..clear()
      ..[id] = file;
    _waiters.remove(id)?.complete(file);
  }

  void handleBinary(Uint8List chunk) {
    final sink = _sink;
    if (sink == null) return;
    // Arrival order: the tail (tailFrom..size) first, then 0..tailFrom.
    final tailLength = _expected - _tailFrom;
    var arrived = sink.length;
    var rest = chunk;
    while (rest.isNotEmpty) {
      final inTail = arrived < tailLength;
      final room = inTail ? tailLength - arrived : rest.length;
      final part = rest.length <= room ? rest : Uint8List.sublistView(rest, 0, room);
      sink.writeAt(inTail ? _tailFrom + arrived : arrived - tailLength, part);
      arrived += part.length;
      rest = Uint8List.sublistView(rest, part.length);
    }
    _growing?.grew();
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

  /// [trackId]'s bytes as they arrive, once its transfer has started (or
  /// finished). Never completes for a track that isn't sent.
  Future<GrowingFile> waitForStart(String trackId) {
    final growing = _growingFiles[trackId];
    if (growing != null) return Future.value(growing);
    return (_startWaiters[trackId] ??= Completer<GrowingFile>()).future;
  }

  void dispose() {
    _abortCurrent();
    _growingFiles.clear();
    _startWaiters.clear();
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.completeError(StateError('Session closed'));
    }
    _waiters.clear();
    _done.clear();
    unawaited(_progress.close());
  }
}
