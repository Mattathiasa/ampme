import 'package:flutter/material.dart';

import '../../../core/network/discovery/discovered_session.dart';
import '../../../theme/amp_tokens.dart';
import '../../../ui/pressable.dart';

/// A session found on the local network; tap to join it.
class SessionListTile extends StatelessWidget {
  const SessionListTile({super.key, required this.discovered, required this.onTap});

  final DiscoveredSession discovered;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        child: Material(
          color: tokens.glass,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AmpTokens.radiusTile),
            side: BorderSide(color: tokens.glassStroke),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: tokens.volt.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.speaker_group_rounded, color: tokens.volt),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(discovered.beacon.sessionName, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                          'Host · ${discovered.beacon.hostIp}',
                          style: TextStyle(
                            color: tokens.textDim,
                            fontSize: 12,
                            fontFamily: AmpTokens.mono,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward_rounded, color: tokens.volt),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
