import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../theme/amp_tokens.dart';

/// Full-screen camera QR scanner. Pops with the first decoded string it
/// sees (the host's join code), or with `null` if the user backs out.
///
/// Push it and await the result:
/// ```dart
/// final code = await Navigator.of(context).push<String>(
///   MaterialPageRoute(builder: (_) => const QrScannerScreen()),
/// );
/// ```
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);

  // Guards against popping twice if several frames decode before the route
  // finishes tearing down.
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;
    _handled = true;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    // The camera view is always dark, whatever the app theme.
    const onCamera = Color(0xFFF4F4F0);
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        foregroundColor: onCamera,
        title: const Text('Scan join code', style: TextStyle(color: onCamera)),
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Volt corner brackets with a sweeping scan line to aim with.
          SizedBox.square(
            dimension: 250,
            child: Stack(
              children: [
                CustomPaint(size: const Size.square(250), painter: _Brackets(tokens.volt)),
                if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false))
                  _ScanLine(color: tokens.volt),
              ],
            ),
          ),
          Positioned(
            bottom: 56,
            left: 24,
            right: 24,
            child: Text(
              'Point the camera at the QR code shown on the host device.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: onCamera, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _Brackets extends CustomPainter {
  _Brackets(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const l = 40.0;
    const r = 18.0;
    final w = size.width;
    final h = size.height;
    for (final (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)]) {
      final x = dx * w;
      final y = dy * h;
      final sx = dx == 0 ? 1 : -1;
      final sy = dy == 0 ? 1 : -1;
      final path = Path()
        ..moveTo(x, y + sy * l)
        ..lineTo(x, y + sy * r)
        ..arcToPoint(Offset(x + sx * r, y), radius: const Radius.circular(r), clockwise: sx == sy)
        ..lineTo(x + sx * l, y);
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_Brackets old) => old.color != color;
}

class _ScanLine extends StatefulWidget {
  const _ScanLine({required this.color});

  final Color color;

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Align(
        alignment: Alignment(0, -0.85 + 1.7 * Curves.easeInOut.transform(_c.value)),
        child: Container(
          height: 3,
          margin: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(3),
            boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 12)],
          ),
        ),
      ),
    );
  }
}
