import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../theme/amp_tokens.dart';
import '../../../ui/glass_card.dart';
import '../../../ui/join_code_display.dart';

/// How other devices get in: the `AMP-` code as big tiles, a QR code (of
/// the join link when there is one, so any phone camera can open it), and
/// the link itself.
class InviteCard extends StatelessWidget {
  const InviteCard({super.key, required this.joinCode, this.joinLink, this.hint});

  final String joinCode;
  final String? joinLink;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final theme = Theme.of(context);
    final link = joinLink;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('INVITE', style: theme.textTheme.labelSmall?.copyWith(color: tokens.textDim)),
          const SizedBox(height: 4),
          Text(
            hint ?? 'Scan, tap the link, or type the code.',
            style: theme.textTheme.bodyMedium?.copyWith(color: tokens.textDim),
          ),
          const SizedBox(height: 18),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                // QR stays dark-on-white whatever the theme: scanners need
                // the contrast.
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: tokens.volt, width: 3),
                boxShadow: tokens.glow(tokens.volt, radius: 36),
              ),
              child: QrImageView(
                data: link ?? joinCode,
                size: 176,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                // Square modules on purpose: rounded ones scan worse at this
                // size on older phones.
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0B0B0F)),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF0B0B0F),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          JoinCodeDisplay(code: joinCode),
          if (link != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.link_rounded, size: 18, color: tokens.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    link,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: AmpTokens.mono,
                      fontSize: 12,
                      color: tokens.textDim,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.content_copy_rounded, size: 18),
                  tooltip: 'Copy link',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: link));
                    HapticFeedback.selectionClick();
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('Join link copied')));
                    }
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
