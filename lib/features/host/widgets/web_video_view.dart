import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'video_fullscreen_button.dart';

/// Shows the host's `<video>` element (owned by `WebHostController`) inside
/// the Flutter page. The element is created once per file and re-parented
/// here, so rebuilding the widget never restarts playback.
///
/// The full-screen button (or a double-click on the picture) puts that same
/// element in browser full screen, so the controller keeps it on the sound;
/// Esc leaves.
class WebVideoView extends StatelessWidget {
  const WebVideoView({super.key, required this.video});

  final web.HTMLVideoElement video;

  void _enterFullscreen() {
    if (web.document.fullscreenElement != null) return;
    video.requestFullscreen().toDart.ignore();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              HtmlElementView.fromTagName(
                // A new key per element: a different file gets a fresh view.
                key: ValueKey(video),
                tagName: 'div',
                onElementCreated: (element) {
                  final host = element as web.HTMLElement;
                  host.style
                    ..width = '100%'
                    ..height = '100%';
                  host.append(video);
                  video.ondblclick = ((web.Event _) => _enterFullscreen()).toJS;
                },
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: VideoFullscreenButton(onPressed: _enterFullscreen),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
