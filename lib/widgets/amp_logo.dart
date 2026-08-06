import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Ampme's brand mark: a rounded gradient tile with a speaker-group glyph.
class AmpLogo extends StatelessWidget {
  const AmpLogo({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.purpleBright, AppTheme.sage],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.4),
            blurRadius: size * 0.3,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      child: Icon(Icons.graphic_eq, size: size * 0.55, color: Colors.white),
    );
  }
}
