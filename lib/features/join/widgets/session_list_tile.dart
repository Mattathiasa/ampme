import 'package:flutter/material.dart';

import '../../../core/network/discovery/session_listener_scanner.dart';

class SessionListTile extends StatelessWidget {
  const SessionListTile({super.key, required this.discovered, required this.onTap});

  final DiscoveredSession discovered;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.speaker_group),
      title: Text(discovered.beacon.sessionName),
      subtitle: Text(discovered.beacon.hostIp),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
