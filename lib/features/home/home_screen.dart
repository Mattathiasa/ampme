import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/amp_logo.dart';
import '../host/host_gate.dart';
import '../join/join_screen.dart';

/// The join code carried by the URL the web app was opened with
/// (`…/web/?join=AMP-7KQ4ZD`), if any. Always null outside the browser.
String? launchJoinCode() {
  if (!kIsWeb) return null;
  final code = Uri.base.queryParameters['join']?.trim();
  return code == null || code.isEmpty ? null : code;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Opened from a join link: go straight to joining. Pushed (rather than
    // replacing home) so Back still lands on the home screen.
    final code = launchJoinCode();
    if (code != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => JoinScreen(initialCode: code)),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.heroGradient(scheme)),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AmpLogo(size: 104),
                  const SizedBox(height: 24),
                  Text(
                    'Ampme',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Play a song on one device and keep every connected phone perfectly in sync.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 40),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HostScreen()),
                    ),
                    icon: const Icon(Icons.podcasts),
                    label: const Text('Host a Session'),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const JoinScreen()),
                    ),
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Join a Session'),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        kIsWeb ? Icons.link : Icons.wifi,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        kIsWeb
                            ? 'Host from your browser — friends join with a code or link.'
                            : 'Works over local WiFi — no cables, no cloud.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
