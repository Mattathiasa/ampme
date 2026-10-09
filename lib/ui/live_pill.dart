import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// A status chip with a dot that pulses while [pulsing] ("● LIVE").
class LivePill extends StatefulWidget {
  const LivePill({super.key, required this.label, this.color, this.pulsing = true});

  final String label;
  final Color? color;
  final bool pulsing;

  @override
  State<LivePill> createState() => _LivePillState();
}

class _LivePillState extends State<LivePill> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(LivePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  void _update() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.pulsing && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final color = widget.color ?? tokens.volt;
    // Shown in caps, announced (and found by the e2e tests) as written.
    return Semantics(
      label: widget.label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: tokens.glow(color, radius: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              widget.label.toUpperCase(),
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
