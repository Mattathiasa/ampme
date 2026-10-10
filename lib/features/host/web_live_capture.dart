import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'tab_share_messages.dart';

/// AudioWorklet that hands the main thread ~43 ms batches of stereo samples,
/// each stamped with the audio-clock frame it starts at (so a silent or
/// stalled input can never shift the timeline).
const String _workletSource = r'''
class AmpmeCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.size = 2048;
    this.reset();
  }
  reset() {
    this.l = new Float32Array(this.size);
    this.r = new Float32Array(this.size);
    this.n = 0;
  }
  process(inputs) {
    const input = inputs[0];
    const left = input && input[0];
    if (!left) return true;
    const right = input[1] || left;
    if (this.n === 0) { this.frame = currentFrame; this.time = currentTime; }
    this.l.set(left, this.n);
    this.r.set(right, this.n);
    this.n += left.length;
    if (this.n >= this.size) {
      this.port.postMessage({ l: this.l, r: this.r, frame: this.frame, time: this.time },
          [this.l.buffer, this.r.buffer]);
      this.reset();
    }
    return true;
  }
}
registerProcessor('ampme-capture', AmpmeCapture);
''';

/// Whether this browser can share another tab's audio: desktop Chrome/Edge
/// (Chromium). Firefox and Safari have screen sharing but never share audio,
/// and mobile browsers can't share tabs; `CaptureController` is a
/// Chromium-only API, so it tells them apart.
bool get canCaptureTabAudio {
  try {
    final devices = web.window.navigator.mediaDevices as JSObject;
    return devices.has('getDisplayMedia') &&
        web.window.has('AudioWorkletNode') &&
        web.window.has('CaptureController');
  } catch (_) {
    return false;
  }
}

/// One captured batch: stereo samples starting at [frame] (audio-clock
/// frames since capture began), whose first sample was rendered at
/// context time [ctxTime].
typedef CaptureBatch = ({int frame, double ctxTime, Float32List left, Float32List right});

/// Captures a shared tab's audio inside the host's [web.AudioContext].
class WebLiveCapture {
  WebLiveCapture._(this.ctx, this.stream);

  final web.AudioContext ctx;
  final web.MediaStream stream;
  web.MediaStreamAudioSourceNode? _source;
  web.AudioWorkletNode? _node;
  web.GainNode? _sink;
  int? _firstFrame;
  final _batches = StreamController<CaptureBatch>.broadcast();

  /// Captured audio, in order.
  Stream<CaptureBatch> get batches => _batches.stream;

  /// Asks the user to pick a tab (with "Share tab audio" ticked) and starts
  /// capturing it. The tab itself is muted locally — this page plays it, on
  /// the shared timeline. Throws [StateError] if no audio was shared.
  static Future<WebLiveCapture> pickTab(web.AudioContext ctx) async {
    final options = <String, Object?>{
      // A video track is required by the API (the picture is discarded);
      // 'browser' opens Chrome/Edge's share dialog on the Tab pane, the only
      // kind of source that can share sound on every OS.
      'video': {'displaySurface': 'browser'},
      'audio': {
        'suppressLocalAudioPlayback': true,
        'echoCancellation': false,
        'noiseSuppression': false,
        'autoGainControl': false,
      },
      'preferCurrentTab': false,
      'selfBrowserSurface': 'exclude',
      'surfaceSwitching': 'include',
      // No "Entire screen": with system audio it would capture Ampme's own
      // playback and feed it back in (an echo that never ends).
      'monitorTypeSurfaces': 'exclude',
      'systemAudio': 'exclude',
    }.jsify()! as web.DisplayMediaStreamOptions;
    final stream = await web.window.navigator.mediaDevices.getDisplayMedia(options).toDart;
    String? surface;
    for (final v in stream.getVideoTracks().toDart) {
      try {
        surface = (v.getSettings() as JSObject).getProperty<JSString?>('displaySurface'.toJS)?.toDart;
      } catch (_) {}
      v.stop();
    }
    if (stream.getAudioTracks().toDart.isEmpty) {
      throw StateError(noTabSoundMessage(surface));
    }
    final capture = WebLiveCapture._(ctx, stream);
    await capture._start();
    return capture;
  }

  Future<void> _start() async {
    final blob = web.Blob(
      [_workletSource.toJS].toJS,
      web.BlobPropertyBag(type: 'application/javascript'),
    );
    final url = web.URL.createObjectURL(blob);
    try {
      await ctx.audioWorklet.addModule(url).toDart;
    } finally {
      web.URL.revokeObjectURL(url);
    }
    final node = web.AudioWorkletNode(
      ctx,
      'ampme-capture',
      web.AudioWorkletNodeOptions(
        numberOfInputs: 1,
        numberOfOutputs: 1,
        channelCount: 2,
        channelCountMode: 'explicit',
      ),
    );
    node.port.onmessage = ((web.MessageEvent e) {
      final d = e.data as JSObject;
      final frame = (d.getProperty<JSNumber>('frame'.toJS)).toDartInt;
      final first = _firstFrame ??= frame;
      if (_batches.isClosed) return;
      _batches.add((
        frame: frame - first,
        ctxTime: d.getProperty<JSNumber>('time'.toJS).toDartDouble,
        left: d.getProperty<JSFloat32Array>('l'.toJS).toDart,
        right: d.getProperty<JSFloat32Array>('r'.toJS).toDart,
      ));
    }).toJS;
    // Keep the worklet pulled by the graph, without making a sound.
    final sink = ctx.createGain()..gain.value = 0;
    node.connect(sink);
    sink.connect(ctx.destination);
    final source = ctx.createMediaStreamSource(stream)..connect(node);
    _source = source;
    _node = node;
    _sink = sink;
  }

  /// Fires when the user stops sharing (browser bar) or the tab closes.
  void onEnded(void Function() callback) {
    for (final t in stream.getAudioTracks().toDart) {
      t.onended = ((web.Event _) => callback()).toJS;
    }
  }

  void stop() {
    for (final t in stream.getTracks().toDart) {
      t.stop();
    }
    for (final n in [_source, _node, _sink]) {
      try {
        n?.disconnect();
      } catch (_) {}
    }
    _source = null;
    _node = null;
    _sink = null;
    unawaited(_batches.close());
  }
}
