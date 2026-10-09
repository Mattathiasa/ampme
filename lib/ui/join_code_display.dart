import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/amp_tokens.dart';

/// The session's `AMP-XXXXXX` code as big mono tiles, with a copy button
/// that morphs into a check once copied.
class JoinCodeDisplay extends StatefulWidget {
  const JoinCodeDisplay({super.key, required this.code});

  final String code;

  @override
  State<JoinCodeDisplay> createState() => _JoinCodeDisplayState();
}

class _JoinCodeDisplayState extends State<JoinCodeDisplay> {
  bool _copied = false;
  Timer? _reset;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    final code = widget.code;
    final dash = code.indexOf('-');
    final prefix = dash > 0 ? code.substring(0, dash) : '';
    final body = dash > 0 ? code.substring(dash + 1) : code;

    return Row(
      children: [
        Expanded(
          child: Semantics(
            label: 'Join code $code',
            excludeSemantics: true,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  if (prefix.isNotEmpty) ...[
                    Text(
                      prefix,
                      style: TextStyle(
                        fontFamily: AmpTokens.mono,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        color: tokens.textDim,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  for (final ch in body.split(''))
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      width: 38,
                      height: 50,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: tokens.volt.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: tokens.volt.withValues(alpha: 0.35)),
                      ),
                      child: Text(
                        ch,
                        style: TextStyle(
                          fontFamily: AmpTokens.mono,
                          fontWeight: FontWeight.w700,
                          fontSize: 26,
                          color: tokens.volt,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          tooltip: 'Copy code',
          onPressed: _copy,
          style: IconButton.styleFrom(
            backgroundColor: _copied ? tokens.volt : tokens.glass,
            foregroundColor: _copied ? tokens.onVolt : null,
            minimumSize: const Size(50, 50),
          ),
          icon: AnimatedSwitcher(
            duration: AmpTokens.medium,
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, key: ValueKey(_copied)),
          ),
        ),
      ],
    );
  }
}
