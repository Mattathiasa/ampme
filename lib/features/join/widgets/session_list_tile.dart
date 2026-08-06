import 'package:flutter/material.dart';

import '../../../core/network/discovery/discovered_session.dart';

class SessionListTile extends StatelessWidget {
  const SessionListTile({super.key, required this.discovered, required this.onTap});

  final DiscoveredSession discovered;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(Icons.speaker_group, color: scheme.onPrimaryContainer),
          ),
          title: Text(
            discovered.beacon.sessionName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text('Host · ${discovered.beacon.hostIp}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}
