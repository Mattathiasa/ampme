import 'package:flutter/material.dart';

/// Web build's stand-in for [HostScreen]. A browser can't run the socket
/// servers a host needs, so hosting is only available on the mobile app.
/// Kept API-compatible (`const HostScreen({super.key})`) so `home_screen`
/// can reference it identically on every platform.
class HostScreen extends StatelessWidget {
  const HostScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Host a Session')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.phonelink, size: 72),
                const SizedBox(height: 16),
                Text(
                  'Hosting is available on the Ampme mobile app',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'A web browser can’t run the local audio server a host needs. '
                  'Host from your phone, then join from here using the session code.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
