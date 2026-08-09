import 'package:flutter/material.dart';

/// Native no-op: the HTTPS-serving banner only makes sense in a browser
/// (this build is never served over HTTPS by a LAN relay, and the real
/// implementation reads `window.location` via `package:web`).
class WebServingNotice extends StatelessWidget {
  const WebServingNotice({super.key});

  static bool get isHttpsServed => false;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
