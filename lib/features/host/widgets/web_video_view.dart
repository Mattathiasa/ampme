import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Shows the host's `<video>` element (owned by `WebHostController`) inside
/// the Flutter page. The element is created once per file and re-parented
/// here, so rebuilding the widget never restarts playback.
class WebVideoView extends StatelessWidget {
  const WebVideoView({super.key, required this.video});

  final web.HTMLVideoElement video;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: HtmlElementView.fromTagName(
            // A new key per element: a different file gets a fresh view.
            key: ValueKey(video),
            tagName: 'div',
            onElementCreated: (element) {
              final host = element as web.HTMLElement;
              host.style
                ..width = '100%'
                ..height = '100%';
              host.append(video);
            },
          ),
        ),
      ),
    );
  }
}
