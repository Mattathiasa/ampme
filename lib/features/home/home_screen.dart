import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/amp_logo.dart';
import '../host/host_gate.dart';
import '../join/join_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
                      Icon(Icons.wifi, size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(
                        'Works over local WiFi — no cables, no cloud.',
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
