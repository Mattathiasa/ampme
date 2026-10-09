import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// Ampme's page transition: the new page fades in while rising slightly and
/// settling from 97 % scale; the old one dims back.
class AmpPageRoute<T> extends PageRouteBuilder<T> {
  AmpPageRoute({required WidgetBuilder builder})
    : super(
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) {
          final a = CurvedAnimation(parent: animation, curve: AmpTokens.ease);
          final out = CurvedAnimation(parent: secondary, curve: AmpTokens.ease);
          return FadeTransition(
            opacity: Tween(begin: 1.0, end: 0.6).animate(out),
            child: FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(a),
                child: ScaleTransition(
                  scale: Tween(begin: 0.97, end: 1.0).animate(a),
                  child: child,
                ),
              ),
            ),
          );
        },
      );
}

/// Fades and lifts [child] in once, [index] steps (60 ms each) after the
/// screen appears — for staggered entrances.
class EnterAnimation extends StatelessWidget {
  const EnterAnimation({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + index * 60),
      curve: Interval(index * 60 / (420 + index * 60), 1, curve: AmpTokens.ease),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}
