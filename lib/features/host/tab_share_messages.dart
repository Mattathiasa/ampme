/// What to tell someone whose tab share came back without sound, by what
/// they picked in the browser's share dialog (`displaySurface` of the video
/// track: `browser`, `window` or `monitor`).
String noTabSoundMessage(String? displaySurface) => switch (displaySurface) {
      'window' || 'monitor' =>
        'Windows and screens don’t share their sound. Click “Share a browser tab” '
            'again and pick the YouTube tab under “Chrome Tab” (or “Edge Tab”).',
      _ => 'That tab was shared without its sound. Click “Share a browser tab” again '
          'and keep “Also share tab audio” switched on.',
    };

/// Shown when a shared tab gives digital silence for a while.
const String silentTabMessage =
    'No sound from that tab yet — is the video playing, and the tab not muted?';
