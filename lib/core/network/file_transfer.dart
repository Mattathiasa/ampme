import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Size of each binary data-channel message carrying song bytes. 16 KiB is
/// the largest size every WebRTC stack (Chrome, Firefox, Safari, libwebrtc
/// on Android) delivers without fragmentation trouble.
const int fileChunkSize = 16 * 1024;

/// Wire format for sending a song over a data channel, host -> listener:
///
///   text   {"type":"file-start","trackId":…,"size":N,"mime":…}
///   binary chunk, chunk, … (exactly N bytes in total, in order)
///   text   {"type":"file-end","trackId":…}
///
/// The channel is reliable and ordered, so no sequence numbers are needed.
abstract final class FileTransferFrames {
  static String start({required String trackId, required int size, String? mime}) =>
      jsonEncode({'type': 'file-start', 'trackId': trackId, 'size': size, 'mime': ?mime});

  static String end(String trackId) => jsonEncode({'type': 'file-end', 'trackId': trackId});

  /// Splits [bytes] into [fileChunkSize] views (no copying).
  static Iterable<Uint8List> chunks(Uint8List bytes, [int size = fileChunkSize]) sync* {
    for (var offset = 0; offset < bytes.length; offset += size) {
      final end = offset + size < bytes.length ? offset + size : bytes.length;
      yield Uint8List.sublistView(bytes, offset, end);
    }
  }
}

/// A received song: its bytes and (if the host knew it) MIME type.
class ReceivedFile {
  const ReceivedFile({required this.trackId, required this.bytes, this.mime});

  final String trackId;
  final Uint8List bytes;
  final String? mime;
}

/// Listener side: reassembles files from [FileTransferFrames] and hands them
/// to whoever is waiting for that track.
class FileReceiver {
  String? _trackId;
  String? _mime;
  int _expected = 0;
  BytesBuilder? _buffer;

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
        _trackId = decoded['trackId'] as String?;
        _mime = decoded['mime'] as String?;
        _expected = (decoded['size'] as num?)?.toInt() ?? 0;
        _buffer = BytesBuilder(copy: true);
        _emitProgress();
      case 'file-end':
        final id = _trackId;
        final buffer = _buffer;
        _trackId = null;
        _buffer = null;
        if (id == null || buffer == null || decoded['trackId'] != id) return;
        if (buffer.length != _expected) return; // truncated — host resends
        final file = ReceivedFile(trackId: id, bytes: buffer.takeBytes(), mime: _mime);
        // Only the newest song is kept: a session plays one at a time.
        _done
          ..clear()
          ..[id] = file;
        _waiters.remove(id)?.complete(file);
    }
  }

  void handleBinary(Uint8List chunk) {
    final buffer = _buffer;
    if (buffer == null) return;
    buffer.add(chunk);
    _emitProgress();
  }

  void _emitProgress() {
    if (_progress.isClosed || _expected <= 0) return;
    _progress.add(((_buffer?.length ?? 0) / _expected).clamp(0.0, 1.0));
  }

  /// The bytes of [trackId] once fully received (immediately if they are).
  Future<ReceivedFile> waitFor(String trackId) {
    final done = _done[trackId];
    if (done != null) return Future.value(done);
    return (_waiters[trackId] ??= Completer<ReceivedFile>()).future;
  }

  void dispose() {
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.completeError(StateError('Session closed'));
    }
    _waiters.clear();
    _done.clear();
    unawaited(_progress.close());
  }
}
