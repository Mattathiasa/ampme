import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/amp_tokens.dart';

/// A song's cover picture: [artwork] is the base64 JPEG/PNG a host sends.
/// A picture that can't be read shows a plain music tile instead.
class ArtworkView extends StatefulWidget {
  const ArtworkView({super.key, required this.artwork, this.size = 72});

  final String artwork;
  final double size;

  @override
  State<ArtworkView> createState() => _ArtworkViewState();
}

class _ArtworkViewState extends State<ArtworkView> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(ArtworkView old) {
    super.didUpdateWidget(old);
    if (old.artwork != widget.artwork) _decode();
  }

  // Decoded once per picture, not on every rebuild (the position ticks
  // each second), or the image would be reloaded and flicker.
  void _decode() {
    try {
      _bytes = base64Decode(widget.artwork);
    } catch (_) {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final radius = BorderRadius.circular(AmpTokens.radiusField);
    final bytes = _bytes;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox.square(
          dimension: widget.size,
          child: bytes == null
              ? ColoredBox(
                  color: tokens.hairline,
                  child: Icon(Icons.music_note_rounded, color: tokens.textDim),
                )
              : Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: tokens.hairline,
                    child: Icon(Icons.music_note_rounded, color: tokens.textDim),
                  ),
                ),
        ),
      ),
    );
  }
}
