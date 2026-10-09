import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// Returns the current output spectrum as levels in 0..1 for [bands] bands,
/// or null when none is available (the visualizer then synthesises one).
typedef SpectrumSampler = List<double>? Function(int bands);

/// Ampme's bar visualizer.
///
/// With a [spectrum] sampler (the browser host's WebAudio analyser) the bars
/// follow the real audio. Without one — phones, whose player exposes no
/// samples — they hold a still equalizer shape while [playing] (see
/// [EqVisualizerState._frozen] for why), and drift gently when [idle].
///
/// Built to be cheap next to an audio player on a slow phone: a 20 fps
/// timer (only those frames are requested) that repaints just this widget's
/// layer — no rebuilds, no blur — stopped once the bars come to rest, while
/// off-stage, and entirely when the platform asks for reduced motion.
class EqVisualizer extends StatefulWidget {
  const EqVisualizer({
    super.key,
    required this.playing,
    this.spectrum,
    this.bars = 28,
    this.height = 72,
    this.color,
    this.idle = false,
  });

  final bool playing;
  final SpectrumSampler? spectrum;
  final int bars;
  final double height;
  final Color? color;

  /// Gentle ambient motion even when nothing plays (the home screen).
  final bool idle;

  @override
  State<EqVisualizer> createState() => EqVisualizerState();
}

@visibleForTesting
class EqVisualizerState extends State<EqVisualizer> {
  /// 20 fps. A [Timer], not a Ticker: a running Ticker asks the engine for
  /// a frame on every vsync (60–120 Hz) even when the tick does nothing,
  /// and on a slow phone those extra frames compete with the audio player.
  static const _frame = Duration(milliseconds: 50);

  Timer? _timer;
  final _clock = Stopwatch();
  final _repaint = ValueNotifier<int>(0);
  late List<double> _levels = List.filled(widget.bars, 0.08);
  bool _reducedMotion = false;
  bool _onScreen = true;

  @visibleForTesting
  bool get isTicking => _timer?.isActive ?? false;

  /// Without real samples, a playing visualizer holds a still shape instead
  /// of animating: A/B runs showed even a 20 fps synthetic animation on a
  /// listener measurably loosening its sync (60–100 ms vs < 10 ms) on a
  /// slow, software-rendered device. Real-spectrum bars (the browser host)
  /// and the idle/home animation (nothing to keep in sync) still move.
  bool get _frozen => widget.playing && widget.spectrum == null;

  bool get _wantsMotion =>
      !_reducedMotion && _onScreen && !_frozen && (widget.playing || widget.idle);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Off-stage (a route underneath, a hidden tab): don't animate.
    _onScreen = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(EqVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bars != widget.bars) _levels = List.filled(widget.bars, 0.08);
    _sync();
  }

  void _sync() {
    if (_frozen) {
      _stop();
      _levels = List.generate(_levels.length, (i) => _synthetic(1.7, i, _levels.length));
      _repaint.value++;
      return;
    }
    // Keep animating after a stop until the bars have fallen back down.
    final run = !_reducedMotion && _onScreen && (_wantsMotion || !_atRest);
    if (run && !isTicking) {
      _clock.start();
      _timer = Timer.periodic(_frame, (_) => _tick());
    } else if (!run && isTicking) {
      _stop();
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  bool get _atRest => _levels.every((v) => v <= 0.09);

  void _tick() {
    final t = _clock.elapsedMicroseconds / 1e6;
    final n = _levels.length;
    final real = widget.playing ? widget.spectrum?.call(n) : null;
    for (var i = 0; i < n; i++) {
      final double target;
      if (real != null && real.length == n) {
        target = real[i].clamp(0.04, 1.0);
      } else if (widget.playing) {
        target = _synthetic(t, i, n);
      } else if (widget.idle) {
        target = 0.10 + 0.14 * (0.5 + 0.5 * math.sin(t * 1.3 + i * 0.45));
      } else {
        target = 0.08;
      }
      final v = _levels[i];
      // Fast attack, slower release: reads as "punchy".
      _levels[i] = v + (target - v) * (target > v ? 0.6 : 0.24);
    }
    _repaint.value++;
    if (!_wantsMotion && _atRest) _stop();
  }

  /// A beat-like pattern: a kick every ~0.47 s weighted to the low bars,
  /// plus drifting mids/highs. Deterministic, so every phone looks alike.
  static double _synthetic(double t, int i, int n) {
    final x = i / math.max(1, n - 1);
    final beat = (t % 0.468) / 0.468;
    final kick = math.exp(-beat * 5) * (1 - x) * 0.75;
    final body = 0.5 + 0.5 * math.sin(t * 2.1 + i * 0.9) * math.cos(t * 0.7 + i * 0.31);
    final shimmer = 0.5 + 0.5 * math.sin(t * 7.3 + i * 2.17);
    final shape = 0.9 - 0.45 * x;
    return (0.12 + kick + body * 0.45 * shape + shimmer * 0.18 * x).clamp(0.06, 1.0);
  }

  @override
  void dispose() {
    _stop();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _EqPainter(
            levels: _levels,
            repaint: _repaint,
            color: widget.color ?? tokens.volt,
            peak: tokens.signal,
          ),
        ),
      ),
    );
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter({
    required this.levels,
    required Listenable repaint,
    required this.color,
    required this.peak,
  }) : super(repaint: repaint);

  final List<double> levels;
  final Color color;
  final Color peak;

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0 || size.isEmpty) return;
    final gap = size.width / n * 0.32;
    final w = (size.width - gap * (n - 1)) / n;
    final bar = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [color, color, Color.lerp(color, peak, 0.85)!],
        stops: const [0, 0.62, 1],
      ).createShader(Offset.zero & size);
    final r = Radius.circular(w / 2);
    for (var i = 0; i < n; i++) {
      final h = math.max(w, size.height * levels[i]);
      final rect = RRect.fromLTRBR(
        i * (w + gap),
        size.height - h,
        i * (w + gap) + w,
        size.height,
        r,
      );
      canvas.drawRRect(rect, bar);
    }
  }

  @override
  bool shouldRepaint(_EqPainter old) =>
      old.color != color || old.peak != peak || old.levels != levels;
}
