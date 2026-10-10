import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Where the ffmpeg.wasm core (~32 MB, cached by the browser) comes from.
/// Overridable for offline tests: `--dart-define=FFMPEG_CORE_BASE=...`.
const String ffmpegCoreBase = String.fromEnvironment(
  'FFMPEG_CORE_BASE',
  defaultValue: 'https://cdn.jsdelivr.net/npm/@ffmpeg/core@0.12.10/dist/umd/',
);

/// Stage of a conversion, for the host UI.
enum FfmpegStage { download, convert }

Future<void>? _bridge;

/// Loads `web/ffmpeg/ampme-ffmpeg.js` once.
Future<void> _loadBridge() => _bridge ??= () {
      final done = Completer<void>();
      final script = web.document.createElement('script') as web.HTMLScriptElement
        ..src = 'ffmpeg/ampme-ffmpeg.js';
      script.onload = ((web.Event _) => done.complete()).toJS;
      script.onerror = ((web.Event _) {
        _bridge = null;
        done.completeError(StateError('Could not load the audio converter.'));
      }).toJS;
      web.document.head!.append(script);
      return done.future;
    }();

/// The first audio track of [bytes] (any container/codec ffmpeg reads —
/// Dolby AC-3/E-AC-3, DTS, MKV…) as stereo Ogg Opus (or WAV), for when the
/// browser's own decoder refuses the file. Downloads the converter on first
/// use; needs an internet connection then.
Future<Uint8List> extractAudioWithFfmpeg(
  Uint8List bytes,
  String fileName, {
  void Function(double progress)? onProgress,
  void Function(FfmpegStage stage)? onStage,
}) async {
  await _loadBridge();
  if (!web.window.has('ampmeExtractAudio')) {
    throw StateError('The audio converter did not start.');
  }
  final promise = web.window.callMethodVarArgs<JSPromise<JSUint8Array>>(
    'ampmeExtractAudio'.toJS,
    [
      bytes.toJS,
      fileName.toJS,
      ffmpegCoreBase.toJS,
      ((JSNumber p) => onProgress?.call(p.toDartDouble)).toJS,
      ((JSString s) => onStage?.call(
            s.toDart == 'download' ? FfmpegStage.download : FfmpegStage.convert,
          )).toJS,
    ],
  );
  try {
    return (await promise.toDart).toDart;
  } catch (e) {
    // A JS Error: its toString() carries the message.
    throw StateError(e.toString().replaceFirst(RegExp(r'^Error: '), ''));
  }
}
