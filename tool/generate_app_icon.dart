// Generates Ampme's launcher icon, adaptive-icon foreground, and splash
// artwork programmatically so the assets stay in sync with the brand palette
// (see lib/theme/amp_tokens.dart and lib/widgets/amp_logo.dart) and can be regenerated anytime:
//
//   dart run tool/generate_app_icon.dart
//
// Then regenerate platform assets:
//   dart run flutter_launcher_icons
//   dart run flutter_native_splash:create
//
// Outputs:
//   assets/icon/app_icon.png              — full 1024x1024 launcher icon
//   assets/icon/app_icon_foreground.png   — adaptive-icon foreground (bars only)
//   assets/splash/splash.png              — native splash artwork (bars on transparent)
import 'dart:io';

import 'package:image/image.dart' as img;

const int _iconSize = 1024;
const int _splashSize = 1024;

// Brand palette (matches AmpTokens.dark).
final _volt = img.ColorRgba8(0xD4, 0xFF, 0x3A, 255); // #D4FF3A
final _ink = img.ColorRgba8(0x0B, 0x0B, 0x0F, 255); // #0B0B0F

// Equalizer-bar heights — the same as AmpLogo.bars.
const List<double> _heights = [0.42, 0.78, 1.0, 0.62, 0.34];

void _fill(img.Image image, img.Color color) =>
    img.fillRect(image, x1: 0, y1: 0, x2: image.width, y2: image.height, color: color);

/// A rounded square [size] wide centred at ([cx], [cy]).
void _tile(img.Image image, double cx, double cy, double size, img.Color color) {
  final h = size / 2;
  img.fillRect(
    image,
    x1: (cx - h).round(),
    y1: (cy - h).round(),
    x2: (cx + h).round(),
    y2: (cy + h).round(),
    radius: (size * 0.3).round(),
    color: color,
  );
}

/// Ampme's five pill-shaped equalizer bars, centred on ([cx], [cy]) and
/// spanning [width] x [height] — the AmpLogo glyph.
void _drawBars(
  img.Image image, {
  required double cx,
  required double cy,
  required double width,
  required double height,
  required img.Color color,
}) {
  const n = 5;
  final w = width / (n * 1.6 - 0.6);
  final gap = w * 0.6;
  var x = cx - width / 2;
  for (var i = 0; i < n; i++) {
    final h = height * _heights[i];
    img.fillRect(
      image,
      x1: x.round(),
      y1: (cy - h / 2).round(),
      x2: (x + w).round(),
      y2: (cy + h / 2).round(),
      radius: (w / 2).round(),
      color: color,
    );
    x += w + gap;
  }
}

void _writePng(img.Image image, String path) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(image));
  stdout.writeln('wrote $path (${image.width}x${image.height})');
}

void main() {
  // 1. Full launcher icon (legacy launchers, web): volt with ink bars.
  final icon = img.Image(width: _iconSize, height: _iconSize, numChannels: 4);
  _fill(icon, _volt);
  _drawBars(
    icon,
    cx: _iconSize / 2,
    cy: _iconSize / 2,
    width: _iconSize * 0.56,
    height: _iconSize * 0.52,
    color: _ink,
  );
  _writePng(icon, 'assets/icon/app_icon.png');

  // 2. Adaptive-icon foreground: ink bars only, inside the safe zone (the
  //    central ~66%); the volt background comes from pubspec.yaml.
  final foreground = img.Image(width: _iconSize, height: _iconSize, numChannels: 4);
  _drawBars(
    foreground,
    cx: _iconSize / 2,
    cy: _iconSize / 2,
    width: _iconSize * 0.40,
    height: _iconSize * 0.36,
    color: _ink,
  );
  _writePng(foreground, 'assets/icon/app_icon_foreground.png');

  // 3. Splash artwork: the volt logo tile on transparent (the splash colour
  //    is ink), small enough for Android 12's circular icon mask.
  final splash = img.Image(width: _splashSize, height: _splashSize, numChannels: 4);
  _tile(splash, _splashSize / 2, _splashSize / 2, _splashSize * 0.5, _volt);
  _drawBars(
    splash,
    cx: _splashSize / 2,
    cy: _splashSize / 2,
    width: _splashSize * 0.28,
    height: _splashSize * 0.26,
    color: _ink,
  );
  _writePng(splash, 'assets/splash/splash.png');
}
