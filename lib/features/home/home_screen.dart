import 'package:flutter/material.dart';

import '../host/host_screen.dart';
import '../join/join_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.speaker_group, size: 96),
                const SizedBox(height: 16),
                Text('Ampme', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                const Text(
                  'Play a song on this device and keep every connected phone in sync.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HostScreen()),
                  ),
                  icon: const Icon(Icons.podcasts),
                  label: const Text('Host a Session'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const JoinScreen()),
                  ),
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('Join a Session'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
