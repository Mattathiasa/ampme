import 'dart:async';
import 'dart:typed_data';

import 'receive_sink.dart';

/// A song that is still arriving: its total [size] is known up front, bytes
/// land in order, and readers can wait for any prefix. Lets a listener start
/// playing once the first ~20 s are in instead of after the whole file.
class GrowingFile {
  GrowingFile({
    required this.trackId,
    required this.size,
    required this.sink,
    int? tailFrom,
    this.mime,
    this.name,
  }) : tailFrom = tailFrom == null || tailFrom > size ? size : tailFrom;

  final String trackId;
  final int size;
  final String? mime;
  final String? name;

  /// Where the bytes are (memory or a temp file).
  final ReceiveSink sink;

  /// The host sends [tailFrom]..end first (players read a file's end before
  /// starting: Ogg and MP3 for duration and tags, MP4 for its index), then
  /// the rest from the start. Equal to [size] when sent in plain order.
  final int tailFrom;

  bool _complete = false;
  Object? _error;
  final List<(int, int, Completer<void>)> _waiters = [];

  int get _tailLength => size - tailFrom;

  /// Bytes from the start of the file that have arrived.
  int get received {
    final body = sink.length - _tailLength;
    return _complete ? size : (body < 0 ? 0 : body);
  }

  bool get isComplete => _complete;
  bool get failed => _error != null;

  bool _available(int start, int end) {
    if (_complete) return true;
    if (start < tailFrom && (end < tailFrom ? end : tailFrom) > received) return false;
    if (end > tailFrom && sink.length < _tailLength) return false;
    return true;
  }

  /// Bytes [start]..[end) once they have arrived (waits for them).
  Future<Uint8List> read(int start, int end) async {
    if (end > size) end = size;
    await waitForRange(start, end);
    return sink.read(start, end);
  }

  /// Completes once the first [bytes] (capped at [size]) have arrived.
  Future<void> waitFor(int bytes) => waitForRange(0, bytes);

  /// Completes once bytes [start]..[end) have arrived; fails if the
  /// transfer is abandoned.
  Future<void> waitForRange(int start, int end) {
    if (end > size) end = size;
    final error = _error;
    if (error != null) return Future.error(error);
    if (start >= end || _available(start, end)) return Future.value();
    final c = Completer<void>();
    _waiters.add((start, end, c));
    return c.future;
  }

  /// The receiver wrote more bytes.
  void grew() {
    if (_waiters.isEmpty) return;
    _waiters.removeWhere((w) {
      if (!_available(w.$1, w.$2)) return false;
      if (!w.$3.isCompleted) w.$3.complete();
      return true;
    });
  }

  void completed() {
    _complete = true;
    for (final w in _waiters) {
      if (!w.$3.isCompleted) w.$3.complete();
    }
    _waiters.clear();
  }

  void fail(Object error) {
    _error = error;
    for (final w in _waiters) {
      if (!w.$3.isCompleted) w.$3.completeError(error);
    }
    _waiters.clear();
  }

  /// Bytes to have before starting: about [lead] of the song (by its average
  /// bitrate, from [durationMs]) plus room for headers, at least 256 KB.
  int startThreshold(int durationMs, {Duration lead = const Duration(seconds: 20)}) =>
      progressiveStartBytes(size: size, durationMs: durationMs, lead: lead);

  /// Waits until playback can start: the end the host sent first, and
  /// about [lead] from the start.
  Future<void> waitUntilStartable(int durationMs) async {
    await waitForRange(tailFrom, size);
    await waitFor(startThreshold(durationMs));
  }
}

/// Where the host starts a song's "end first" part for a listener that
/// supports it ([GrowingFile.tailFrom]); [bytes].length for plain order.
/// The last 64 KB for most files; for an MP4 whose index (`moov`) sits
/// after the audio, everything from the index on (if it's not huge).
int tailFirstFrom(Uint8List bytes, String? mime) {
  const plainTail = 64 * 1024;
  if (bytes.length < 1024 * 1024) return bytes.length; // small: no benefit
  final m = (mime ?? '').toLowerCase();
  if (m.contains('mp4') || m.contains('m4a') || m.contains('quicktime')) {
    final moov = _topLevelBox(bytes, 'moov');
    if (moov != null && !_moovFirst(bytes)) {
      final tail = bytes.length - moov;
      return tail <= 16 * 1024 * 1024 ? moov : bytes.length;
    }
  }
  return bytes.length - plainTail;
}

int? _topLevelBox(Uint8List bytes, String type) {
  final data = ByteData.sublistView(bytes);
  var offset = 0;
  while (offset + 8 <= bytes.length) {
    var boxSize = data.getUint32(offset);
    if (String.fromCharCodes(bytes.sublist(offset + 4, offset + 8)) == type) return offset;
    if (boxSize == 1) {
      if (offset + 16 > bytes.length) return null;
      boxSize = data.getUint32(offset + 8) * 0x100000000 + data.getUint32(offset + 12);
    } else if (boxSize == 0) {
      return null; // box runs to the end of the file
    }
    if (boxSize < 8) return null;
    offset += boxSize;
  }
  return null;
}

/// See [GrowingFile.startThreshold]; shared with the host, which uses it to
/// tell when a listener can already start.
int progressiveStartBytes({
  required int size,
  required int durationMs,
  Duration lead = const Duration(seconds: 20),
}) {
  if (durationMs <= 0) return size;
  final share = size * lead.inMilliseconds ~/ durationMs + 64 * 1024;
  final want = share < 256 * 1024 ? 256 * 1024 : share;
  return want > size ? size : want;
}

/// Whether a player can start this file from its first bytes. MP3, Ogg,
/// WAV, FLAC and WebM can. An MP4/M4A can only if its index (`moov`) comes
/// before the audio (`mdat`); otherwise the player must read the end first,
/// so it has to wait for the whole file — unless the host sent the index
/// first ([indexSentFirst]). [head] is the first bytes received (64 KB is
/// plenty to see the box order).
bool isProgressivelyPlayable(String? mime, Uint8List head, {bool indexSentFirst = false}) {
  final m = (mime ?? '').toLowerCase();
  if (m.contains('mp4') || m.contains('m4a') || m.contains('aac') || m.contains('quicktime')) {
    return indexSentFirst || _moovFirst(head);
  }
  return m.contains('mpeg') ||
      m.contains('mp3') ||
      m.contains('ogg') ||
      m.contains('opus') ||
      m.contains('wav') ||
      m.contains('flac') ||
      m.contains('webm');
}

/// Whether a player seeks in this format by computing a byte offset (WAV)
/// or from an index it already has (MP4 — playable progressively only with
/// its index), rather than by probing across the file (Ogg, MP3, FLAC, WebM).
bool seeksDirectly(String? mime) {
  final m = (mime ?? '').toLowerCase();
  return m.contains('wav') || m.contains('mp4') || m.contains('m4a') || m.contains('quicktime');
}

bool _moovFirst(Uint8List head) {
  // Raw ADTS AAC (no boxes) streams fine.
  if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xF6) == 0xF0) return true;
  final data = ByteData.sublistView(head);
  var offset = 0;
  while (offset + 8 <= head.length) {
    var boxSize = data.getUint32(offset);
    final type = String.fromCharCodes(head.sublist(offset + 4, offset + 8));
    if (type == 'moov') return true;
    if (type == 'mdat') return false;
    if (boxSize == 1) {
      if (offset + 16 > head.length) return false;
      boxSize = data.getUint32(offset + 8) * 0x100000000 + data.getUint32(offset + 12);
    }
    if (boxSize < 8) return false;
    offset += boxSize;
  }
  return false; // didn't see either within the head: play it safe
}
