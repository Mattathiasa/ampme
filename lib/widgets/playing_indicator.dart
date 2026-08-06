import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small set of animated bars that "dance" while audio is playing and rest
/// flat when paused/stopped — a lightweight now-playing affordance.
class PlayingIndicator extends StatefulWidget {
  const PlayingIndicator({
    super.key,
    required this.isPlaying,
    this.color,
    this.size = 22,
    this.barCount = 4,
  });

  final bool isPlaying;
  final Color? color;
  final double size;
  final int barCount;

  @override
  State<PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<PlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.isPlaying) _controller.repeat();
  }

  @override
  void didUpdateWidget(PlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isPlaying && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final barWidth = widget.size / (widget.barCount * 2 - 1);

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(widget.barCount, (i) {
              final phase = _controller.value * 2 * math.pi + i * 1.3;
              final t = widget.isPlaying ? (math.sin(phase) + 1) / 2 : 0.15;
              final h = widget.size * (0.25 + 0.75 * t);
              return Container(
                width: barWidth,
                height: h,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(barWidth),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
