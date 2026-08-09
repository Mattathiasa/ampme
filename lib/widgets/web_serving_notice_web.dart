import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Banner shown on the web build when it's served over **HTTPS** (e.g. the
/// GitHub Pages copy at `/ampme/web/`).
///
/// Browsers treat an HTTPS page connecting to a plain-HTTP LAN host
/// (`http://192.168.x.x` / `ws://`) as mixed content and block it, so
/// hosting and joining real sessions require the app to be served over HTTP
/// from the LAN relay (`dart run tool/web_relay.dart`). Showing this instead
/// of a silently-broken connection screen keeps the GitHub Pages copy
/// honest: it renders the full UI, but the actual host/join flows run from
/// the LAN URL the relay prints.
class WebServingNotice extends StatelessWidget {
  const WebServingNotice({super.key});

  /// Whether this page is served over HTTPS — only possible when it is NOT
  /// the LAN relay (which is plain HTTP), so it's a reliable signal that
  /// in-app LAN connections will be blocked by the browser.
  static bool get isHttpsServed {
    if (!kIsWeb) return false;
    try {
      return web.window.location.protocol.startsWith('https');
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isHttpsServed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This is the hosted web preview. Browsers block secure (HTTPS) '
              'pages from reaching devices on your WiFi, so hosting and '
              'joining run from the LAN version: on any computer on the same '
              'network, run `dart run tool/web_relay.dart` and open the '
              'http://<lan-ip>:8080 address it prints. Or use the Android / '
              'Windows apps.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
