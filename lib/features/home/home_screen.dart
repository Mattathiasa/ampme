import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/amp_tokens.dart';
import '../../ui/amp_button.dart';
import '../../ui/amp_page_route.dart';
import '../../ui/eq_visualizer.dart';
import '../../ui/glass_card.dart';
import '../../ui/live_pill.dart';
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
        Navigator.of(context).push(AmpPageRoute(builder: (_) => JoinScreen(initialCode: code)));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AmpTokens.of(context);
    final display = theme.textTheme.displayLarge;
    // Short screens (small phones, landscape, the 800×600 test surface)
    // tighten up so both actions stay above the fold.
    final compact = MediaQuery.sizeOf(context).height < 720;
    final gap = compact ? 18.0 : 32.0;

    return Scaffold(
      body: AmpBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EnterAnimation(
                      child: Row(
                        children: [
                          const AmpLogo(size: 40),
                          const SizedBox(width: 12),
                          Text(
                            'AMPME',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontFamily: AmpTokens.display,
                              letterSpacing: 2,
                            ),
                          ),
                          const Spacer(),
                          LivePill(label: kIsWeb ? 'Any browser' : 'Same WiFi', pulsing: false),
                        ],
                      ),
                    ),
                    SizedBox(height: compact ? 20 : 48),
                    EnterAnimation(
                      index: 1,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: 'ONE ROOM.\n'),
                            TextSpan(
                              text: 'ONE BEAT.',
                              style: TextStyle(color: tokens.volt),
                            ),
                          ],
                        ),
                        style: display?.copyWith(fontSize: compact ? 44 : 60),
                      ),
                    ),
                    const SizedBox(height: 18),
                    EnterAnimation(
                      index: 2,
                      child: Text(
                        'Every phone in the room plays the same song at the same '
                        'instant — one giant speaker, no cables.',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: tokens.textDim,
                          height: 1.45,
                        ),
                      ),
                    ),
                    SizedBox(height: gap),
                    EnterAnimation(
                      index: 3,
                      child: EqVisualizer(
                        playing: false,
                        idle: true,
                        bars: 34,
                        height: compact ? 56 : 110,
                      ),
                    ),
                    SizedBox(height: gap),
                    EnterAnimation(
                      index: 4,
                      child: AmpButton(
                        label: 'Host a Session',
                        icon: Icons.podcasts_rounded,
                        onPressed: () => Navigator.of(
                          context,
                        ).push(AmpPageRoute(builder: (_) => const HostScreen())),
                      ),
                    ),
                    const SizedBox(height: 12),
                    EnterAnimation(
                      index: 5,
                      child: AmpButton(
                        label: 'Join a Session',
                        icon: Icons.wifi_tethering_rounded,
                        kind: AmpButtonKind.ghost,
                        onPressed: () => Navigator.of(
                          context,
                        ).push(AmpPageRoute(builder: (_) => const JoinScreen())),
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 28),
                      EnterAnimation(
                        index: 6,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            for (final (icon, text) in [
                              (Icons.bolt_rounded, 'Synced to ±20 ms'),
                              (Icons.movie_rounded, 'Songs · videos · tabs'),
                              (
                                kIsWeb ? Icons.link_rounded : Icons.wifi_rounded,
                                kIsWeb ? 'Join by code or link' : 'Local WiFi, no cloud',
                              ),
                            ])
                              Chip(
                                avatar: Icon(icon, size: 16, color: tokens.volt),
                                label: Text(text),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
