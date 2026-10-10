import 'package:flutter/material.dart';

/// The round "Full screen" / "Exit full screen" button drawn over a video.
class VideoFullscreenButton extends StatelessWidget {
  const VideoFullscreenButton({super.key, required this.onPressed, this.exit = false});

  final VoidCallback onPressed;
  final bool exit;

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      tooltip: exit ? 'Exit full screen' : 'Full screen',
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.55),
        foregroundColor: Colors.white,
      ),
      icon: Icon(exit ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
    );
  }
}
