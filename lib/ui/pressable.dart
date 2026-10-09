import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// Shrinks its child slightly while a pointer is down — the tactile "push"
/// every Ampme control has. Purely visual: taps still go to the child.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.enabled = true, this.scale = 0.96});

  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down && mounted) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: widget.enabled ? (_) => _set(true) : null,
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: AmpTokens.fast,
        curve: AmpTokens.ease,
        child: widget.child,
      ),
    );
  }
}
