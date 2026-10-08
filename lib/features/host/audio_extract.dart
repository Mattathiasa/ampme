import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../core/audio/ogg_opus_writer.dart';
import '../../core/audio/wav_writer.dart';
import '../../core/observability/reporting.dart';

/// A video's sound, ready to send to listeners.
class ExtractedAudio {
  const ExtractedAudio(this.bytes, this.mime, this.extension);

  final Uint8List bytes;
  final String mime;
  final String extension;
}

/// Largest WAV the fallback will produce (browsers without WebCodecs).
const int _maxWavBytes = 400 * 1024 * 1024;

/// Makes an audio-only copy of an already-decoded video sound track.
///
/// Phones only play the sound, so sending them the whole video wastes
/// bandwidth and makes them demux/decode a picture nobody sees (on a slow
/// phone that starves the audio output and breaks sync). Encodes Opus
/// (128 kbps, ≈1 MB/min) with WebCodecs when the browser has it, else a
/// 16-bit WAV. Throws if the sound is too long for the WAV fallback.
Future<ExtractedAudio> extractAudio(
  web.AudioBuffer buffer, {
  void Function(double progress)? onProgress,
}) async {
  if (_hasAudioEncoder) {
    try {
      final ogg = await _encodeOpus(buffer, onProgress: onProgress);
      return ExtractedAudio(ogg, 'audio/ogg', 'ogg');
    } catch (e, st) {
      // Encoder present but unusable here: fall back to WAV (bigger, works).
      reportError(e, st, context: 'extractAudio.opus');
    }
  }
  return _encodeWav(buffer);
}

bool get _hasAudioEncoder => web.window.has('AudioEncoder');

/// A plain JS object with [props] (values already JS).
JSObject _obj(Map<String, JSAny?> props) {
  final o = JSObject();
  props.forEach((k, v) => o.setProperty(k.toJS, v));
  return o;
}

ExtractedAudio _encodeWav(web.AudioBuffer buffer) {
  final channels = math.min(buffer.numberOfChannels, 2);
  var rate = buffer.sampleRate.round();
  var data = [for (var c = 0; c < channels; c++) buffer.getChannelData(c).toDart];
  // Halve the rate (simple 2:1 decimation with averaging) if that's what it
  // takes to fit; long films without WebCodecs still get through.
  if (data.first.length * channels * 2 > _maxWavBytes) {
    data = [
      for (final ch in data)
        Float32List.fromList([
          for (var i = 0; i + 1 < ch.length; i += 2) (ch[i] + ch[i + 1]) / 2,
        ]),
    ];
    rate ~/= 2;
  }
  if (data.first.length * channels * 2 > _maxWavBytes) {
    throw StateError(
      'This video is too long to send its sound to phones from this browser. '
      'Use Chrome or Edge, or a shorter video.',
    );
  }
  return ExtractedAudio(wavFromPcm(data, rate), 'audio/wav', 'wav');
}

// ---- WebCodecs (not in package:web yet) ----

@JS('AudioEncoder')
extension type _AudioEncoder._(JSObject _) implements JSObject {
  external factory _AudioEncoder(JSObject init);
  external void configure(JSObject config);
  external void encode(JSObject data);
  external JSPromise<JSAny?> flush();
  external void close();
  external int get encodeQueueSize;
}

@JS('AudioData')
extension type _AudioData._(JSObject _) implements JSObject {
  external factory _AudioData(JSObject init);
  external void close();
}

extension type _EncodedAudioChunk._(JSObject _) implements JSObject {
  external int get byteLength;
  external double? get duration; // µs
  external void copyTo(JSObject destination);
}

Future<Uint8List> _encodeOpus(
  web.AudioBuffer source, {
  void Function(double progress)? onProgress,
}) async {
  const rate = 48000; // Opus encodes at 48 kHz
  final buffer = source.sampleRate == rate ? source : await _resample(source, rate);
  final channels = math.min(buffer.numberOfChannels, 2);
  final frames = buffer.length;

  final writer = _OpusCollector(channels);
  Object? failure;
  final encoder = _AudioEncoder(
    _obj({
      'output': ((JSObject chunk, JSObject? metadata) => writer.add(chunk, metadata)).toJS,
      'error': ((JSAny? e) {
        failure = e ?? 'unknown';
      }).toJS,
    }),
  );
  try {
    encoder.configure(
      _obj({
        'codec': 'opus'.toJS,
        'sampleRate': rate.toJS,
        'numberOfChannels': channels.toJS,
        'bitrate': 128000.toJS,
      }),
    );
    final planes = [for (var c = 0; c < channels; c++) buffer.getChannelData(c).toDart];
    const block = rate; // 1 s per AudioData
    for (var start = 0; start < frames; start += block) {
      if (failure != null) throw StateError('Opus encoding failed: $failure');
      final n = math.min(block, frames - start);
      final planar = Float32List(n * channels);
      for (var c = 0; c < channels; c++) {
        planar.setRange(c * n, (c + 1) * n, planes[c], start);
      }
      final data = _AudioData(
        _obj({
          'format': 'f32-planar'.toJS,
          'sampleRate': rate.toJS,
          'numberOfFrames': n.toJS,
          'numberOfChannels': channels.toJS,
          'timestamp': (start * 1000000 ~/ rate).toJS,
          'data': planar.toJS,
        }),
      );
      encoder.encode(data);
      data.close();
      // Keep the queue short so memory stays flat and progress is honest.
      while (encoder.encodeQueueSize > 8) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      onProgress?.call((start + n) / frames);
    }
    await encoder.flush().toDart;
    if (failure != null) throw StateError('Opus encoding failed: $failure');
    return writer.finish(totalSamples48k: frames);
  } finally {
    try {
      encoder.close();
    } catch (_) {}
  }
}

/// Collects encoder output into an Ogg Opus file, taking the encoder's real
/// look-ahead (pre-skip) from the OpusHead it reports when it does.
class _OpusCollector {
  _OpusCollector(this.channels);

  final int channels;
  OggOpusWriter? _writer;
  final List<(Uint8List, int)> _early = [];

  void add(JSObject chunkObj, JSObject? metadata) {
    final chunk = chunkObj as _EncodedAudioChunk;
    final bytes = Uint8List(chunk.byteLength);
    chunk.copyTo(bytes.toJS);
    final samples = ((chunk.duration ?? 20000) * 48 / 1000).round();
    var writer = _writer;
    if (writer == null) {
      writer = _writer = OggOpusWriter(channels: channels, preSkip: _preSkip(metadata) ?? 312);
      for (final (b, s) in _early) {
        writer.addPacket(b, s);
      }
      _early.clear();
    }
    writer.addPacket(bytes, samples);
  }

  int? _preSkip(JSObject? metadata) {
    try {
      final config = metadata?.getProperty<JSObject?>('decoderConfig'.toJS);
      final desc = config?.getProperty<JSAny?>('description'.toJS);
      if (desc == null) return null;
      final Uint8List head;
      if (desc.isA<JSArrayBuffer>()) {
        head = (desc as JSArrayBuffer).toDart.asUint8List();
      } else if (desc.isA<JSUint8Array>()) {
        head = (desc as JSUint8Array).toDart;
      } else {
        return null;
      }
      if (head.length < 12 || String.fromCharCodes(head.sublist(0, 8)) != 'OpusHead') {
        return null;
      }
      return head[10] | (head[11] << 8);
    } catch (_) {
      return null;
    }
  }

  Uint8List finish({required int totalSamples48k}) =>
      (_writer ?? OggOpusWriter(channels: channels)).finish(totalSamples48k: totalSamples48k);
}

Future<web.AudioBuffer> _resample(web.AudioBuffer source, int rate) async {
  final length = (source.duration * rate).ceil();
  final ctx = web.OfflineAudioContext(
    web.OfflineAudioContextOptions(
      numberOfChannels: math.min(source.numberOfChannels, 2),
      length: length,
      sampleRate: rate.toDouble(),
    ),
  );
  final node = ctx.createBufferSource()..buffer = source;
  node.connect(ctx.destination);
  node.start();
  return ctx.startRendering().toDart;
}
