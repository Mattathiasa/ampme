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

/// A song could not be received (refused, abandoned, stalled, or too much
/// data); whoever was waiting for it gets this.
class FileTransferException implements Exception {
  const FileTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Listener side: reassembles files from [FileTransferFrames] and hands them
/// to whoever is waiting for that track. Where the bytes go is up to
/// [sinkFactory]: memory by default, a temp file on Android (so a large video
/// never sits in RAM).
class FileReceiver {
  FileReceiver({
    ReceiveSinkFactory? sinkFactory,
    this.maxFileBytes = defaultMaxFileBytes,
    this.stallTimeout = const Duration(seconds: 60),
  }) : _sinkFactory = sinkFactory ?? MemoryReceiveSink.new;

  /// The largest song accepted (the web host itself sends at most 1 GiB).
  /// The announced size decides how much memory or disk is set aside, so a
  /// host can't ask for more than this.
  static const int defaultMaxFileBytes = 1024 * 1024 * 1024;
  final int maxFileBytes;

  /// A transfer that receives nothing for this long is given up on, so
  /// whoever waits for the song gets an error instead of waiting for ever.
  final Duration stallTimeout;
  Timer? _stall;

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
        final id = decoded['trackId'];
        final size = decoded['size'];
        if (id is! String || id.isEmpty || id.length > 200) return;
        final previous = _trackId;
        _abortCurrent(); // an unfinished earlier transfer is superseded
        // Anyone waiting for a different, abandoned song stops waiting; the
        // same song restarting (a host re-sending) keeps its waiters.
        if (previous != null && previous != id) {
          _failWaiters(previous, const FileTransferException('Superseded by another song'));
        }
        if (size is! num || size < 0 || size > maxFileBytes) {
          _failWaiters(id, FileTransferException('Refused a song of size $size'));
          return;
        }
        final expected = size.toInt();
        final tailFrom = (decoded['tailFrom'] as num?)?.toInt();
        final name = decoded['name'] is String ? decoded['name'] as String : null;
        final mime = decoded['mime'] is String ? decoded['mime'] as String : null;
        final ReceiveSink sink;
        try {
          sink = _sinkFactory(trackId: id, name: name, mime: mime, size: expected);
        } catch (e) {
          // No room (memory or disk): nothing half-started is left behind.
          _failWaiters(id, FileTransferException('Could not prepare to receive the song: $e'));
          return;
        }
        _trackId = id;
        _expected = expected;
        _tailFrom = tailFrom == null || tailFrom < 0 || tailFrom > expected ? expected : tailFrom;
        _sink = sink;
        final growing = _growing = GrowingFile(
          trackId: id,
          size: expected,
          sink: sink,
          tailFrom: _tailFrom,
          mime: mime,
          name: name,
        );
        // One song at a time: an older growing file is no longer served.
        _growingFiles
          ..clear()
          ..[id] = growing;
        _startWaiters.remove(id)?.complete(growing);
        _watchForStall();
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
        _stall?.cancel();
        _stall = null;
        _trackId = null;
        _sink = null;
        _growing = null;
        unawaited(_finish(id, sink, growing));
    }
  }

  void _abortCurrent([Object? error]) {
    final id = _trackId;
    _stall?.cancel();
    _stall = null;
    _growing?.fail(error ?? const FileTransferException('Transfer abandoned'));
    if (id != null) _growingFiles.remove(id);
    _sink?.abort();
    _trackId = null;
    _sink = null;
    _growing = null;
  }

  /// Gives up on the transfer in progress: readers of its bytes and anyone
  /// waiting for the finished song get [error].
  void _fail(Object error) {
    final id = _trackId;
    _abortCurrent(error);
    if (id != null) _failWaiters(id, error);
  }

  void _failWaiters(String id, Object error) {
    _waiters.remove(id)?.completeError(error);
    _startWaiters.remove(id)?.completeError(error);
  }

  DateTime _lastChunkAt = DateTime.now();

  void _watchForStall() {
    _stall?.cancel();
    _lastChunkAt = DateTime.now();
    _stall = Timer.periodic(stallTimeout ~/ 4, (_) {
      if (_sink != null && DateTime.now().difference(_lastChunkAt) > stallTimeout) {
        _fail(const FileTransferException('The song stopped arriving'));
      }
    });
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
    if (sink.length + chunk.length > _expected) {
      // More than the host announced: never write past the size reserved.
      _fail(const FileTransferException('The host sent more than it announced'));
      return;
    }
    _lastChunkAt = DateTime.now();
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
