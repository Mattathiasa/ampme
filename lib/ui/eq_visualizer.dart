import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// Returns the current output spectrum as levels in 0..1 for [bands] bands,
/// or null when none is available (the visualizer then synthesises one).
typedef SpectrumSampler = List<double>? Function(int bands);

/// Ampme's bar visualizer.
///
/// With a [spectrum] sampler (the browser host's WebAudio analyser) the bars
/// follow the real audio. Without one — phones, whose player exposes no
/// samples — they move to a deterministic beat-like pattern while [playing].
///
/// Built to be cheap next to an audio player on a slow phone: one ticker
/// throttled to ~30 fps that only repaints this widget's layer (no
/// rebuilds), stopped once the bars come to rest, and off entirely when the
/// platform asks for reduced motion.
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
class EqVisualizerState extends State<EqVisualizer> with SingleTickerProviderStateMixin {
  static const _frame = Duration(milliseconds: 33);

  late final Ticker _ticker = createTicker(_tick);
  final _repaint = ValueNotifier<int>(0);
  late List<double> _levels = List.filled(widget.bars, 0.08);
  Duration _last = Duration.zero;
  bool _reducedMotion = false;

  @visibleForTesting
  bool get isTicking => _ticker.isActive;

  bool get _wantsMotion => !_reducedMotion && (widget.playing || widget.idle);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(EqVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bars != widget.bars) _levels = List.filled(widget.bars, 0.08);
    _sync();
  }

  void _sync() {
    // Keep ticking after a stop until the bars have fallen back down.
    if ((_wantsMotion || !_atRest) && !_reducedMotion) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
      _last = Duration.zero;
    }
  }

  bool get _atRest => _levels.every((v) => v <= 0.09);

  void _tick(Duration elapsed) {
    if (elapsed - _last < _frame) return;
    _last = elapsed;
    final t = elapsed.inMicroseconds / 1e6;
    final n = _levels.length;
    final real = widget.playing ? widget.spectrum?.call(n) : null;
    for (var i = 0; i < n; i++) {
      final double target;
      if (real != null && real.length == n) {
        target = real[i].clamp(0.04, 1.0);
      } else if (widget.playing) {
        target = _synthetic(t, i, n);
      } else if (widget.idle && !_reducedMotion) {
        target = 0.10 + 0.14 * (0.5 + 0.5 * math.sin(t * 1.3 + i * 0.45));
      } else {
        target = 0.08;
      }
      final v = _levels[i];
      // Fast attack, slower release: reads as "punchy".
      _levels[i] = v + (target - v) * (target > v ? 0.55 : 0.18);
    }
    _repaint.value++;
    if (!_wantsMotion && _atRest) {
      _ticker.stop();
      _last = Duration.zero;
    }
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
    _ticker.dispose();
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
            glow: tokens.glowStrength,
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
    required this.glow,
  }) : super(repaint: repaint);

  final List<double> levels;
  final Color color;
  final Color peak;
  final double glow;

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
    final halo = glow > 0
        ? (Paint()
            ..color = color.withValues(alpha: 0.22 * glow)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6))
        : null;
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
      if (halo != null && levels[i] > 0.5) canvas.drawRRect(rect, halo);
      canvas.drawRRect(rect, bar);
    }
  }

  @override
  bool shouldRepaint(_EqPainter old) =>
      old.color != color || old.peak != peak || old.levels != levels;
}
