import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/amp_tokens.dart';

/// The join-code input: one big monospace field that upper-cases as you
/// type. Also accepts a raw `ip:port` for local-network hosts.
class CodeField extends StatelessWidget {
  const CodeField({super.key, required this.controller, this.onSubmitted});

  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final tokens = AmpTokens.of(context);
    return TextField(
      controller: controller,
      textCapitalization: TextCapitalization.characters,
      autocorrect: false,
      enableSuggestions: false,
      inputFormatters: [UpperCaseFormatter()],
      style: TextStyle(
        fontFamily: AmpTokens.mono,
        fontWeight: FontWeight.w700,
        fontSize: 22,
        letterSpacing: 2.5,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      cursorColor: tokens.volt,
      decoration: InputDecoration(
        labelText: 'Join by code',
        hintText: 'AMP-7KQ4ZD',
        hintStyle: TextStyle(
          fontFamily: AmpTokens.mono,
          color: tokens.textDim.withValues(alpha: 0.45),
          letterSpacing: 2.5,
        ),
        prefixIcon: Icon(Icons.tag_rounded, color: tokens.volt),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      ),
      onSubmitted: onSubmitted,
    );
  }
}

/// Upper-cases typed text, keeping the cursor where it was.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
