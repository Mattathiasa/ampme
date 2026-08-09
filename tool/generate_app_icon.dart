// Generates Ampme's launcher icon, adaptive-icon foreground, and splash
// artwork programmatically so the assets stay in sync with the brand palette
// (see lib/theme/app_theme.dart) and can be regenerated anytime:
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

// Brand palette (matches AppTheme).
const _purpleBright = (155, 123, 255); // #9B7BFF
const _sage = (157, 179, 138); // #9DB38A
const _bgTop = (42, 30, 74); // #2A1E4A
const _bgBottom = (20, 15, 31); // #140F1F

// Equalizer-bar heights (fractions of the drawing-area height).
const List<double> _heights = [0.42, 0.72, 1.0, 0.58, 0.85];
const int _barCount = 5;

img.ColorRgba8 _lerp(
  (int, int, int) a,
  (int, int, int) b,
  double t,
) {
  return img.ColorRgba8(
    (a.$1 + (b.$1 - a.$1) * t).round(),
    (a.$2 + (b.$2 - a.$2) * t).round(),
    (a.$3 + (b.$3 - a.$3) * t).round(),
    255,
  );
}

/// Vertical brand gradient used behind the launcher icon.
void _fillGradientBackground(img.Image image) {
  for (var y = 0; y < image.height; y++) {
    final t = y / (image.height - 1);
    final color = _lerp(_bgTop, _bgBottom, t);
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgba(x, y, color.r, color.g, color.b, color.a);
    }
  }
}

/// Draws the Ampme equalizer-waveform, centered at [cx] with its baseline at
/// [baselineY], spanning [totalWidth] and up to [maxHeight] tall. Bar colour
/// fades from brand purple to sage across the row (matching the AmpLogo).
void _drawWaveform(
  img.Image image, {
  required double cx,
  required double baselineY,
  required double totalWidth,
  required double maxHeight,
}) {
  final barWidth = totalWidth / (_barCount + (_barCount - 1) * 0.6);
  final gap = barWidth * 0.6;
  var x = cx - totalWidth / 2;
  for (var i = 0; i < _barCount; i++) {
    final h = maxHeight * _heights[i];
    final t = _barCount == 1 ? 0.0 : i / (_barCount - 1);
    final color = _lerp(_purpleBright, _sage, t);
    final x1 = x.round();
    final x2 = (x + barWidth).round();
    final y1 = (baselineY - h).round();
    final y2 = baselineY.round();
    img.fillRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: color);
    // Rounded cap so bars read as soft equalizer peaks, not harsh blocks.
    img.fillCircle(
      image,
      x: (x + barWidth / 2).round(),
      y: y1,
      radius: (barWidth / 2).round(),
      color: color,
    );
    x += barWidth + gap;
  }
}

void _writePng(img.Image image, String path) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(image));
  stdout.writeln('wrote $path (${image.width}x${image.height})');
}

void main() {
  // 1. Full launcher icon: brand gradient + waveform.
  final icon = img.Image(width: _iconSize, height: _iconSize);
  _fillGradientBackground(icon);
  _drawWaveform(
    icon,
    cx: _iconSize / 2,
    baselineY: _iconSize * 0.81,
    totalWidth: _iconSize * 0.50,
    maxHeight: _iconSize * 0.58,
  );
  _writePng(icon, 'assets/icon/app_icon.png');

  // 2. Adaptive-icon foreground: bars only, centred inside the safe zone
  //    (content must fit within the central ~66% of the canvas).
  final foreground = img.Image(width: _iconSize, height: _iconSize);
  _drawWaveform(
    foreground,
    cx: _iconSize / 2,
    baselineY: _iconSize * 0.70,
    totalWidth: _iconSize * 0.42,
    maxHeight: _iconSize * 0.40,
  );
  _writePng(foreground, 'assets/icon/app_icon_foreground.png');

  // 3. Splash artwork: bars on transparent, sized for the native splash.
  final splash = img.Image(width: _splashSize, height: _splashSize);
  _drawWaveform(
    splash,
    cx: _splashSize / 2,
    baselineY: _splashSize * 0.58,
    totalWidth: _splashSize * 0.46,
    maxHeight: _splashSize * 0.36,
  );
  _writePng(splash, 'assets/splash/splash.png');
}
