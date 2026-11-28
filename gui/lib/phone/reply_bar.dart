/// The phone session's reply bar (V1c Task 14): 「按住说话，回一句」 and a 「打字」 square beside it. Tokens only.
library;

import 'package:flutter/material.dart';

import '../embed/voice_button.dart';
import '../ui/tokens.dart';
import 'phone_voice.dart';
import 'widgets.dart';

const replyBarVoiceLabel = '按住说话，回一句';

/// [hold] is null without a recogniser (V6): then only the square shows. [open] turns the square into 「收起」.
class PhoneReplyBar extends StatelessWidget {
  const PhoneReplyBar({super.key, required this.hold, this.onType, this.open = false});
  final VoiceHold? hold;

  /// Null hides the square (the session takes no typed input).
  final VoidCallback? onType;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final h = hold;
    final label = open ? '收起' : '打字输入';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (h != null) ...[
          Expanded(
            child: SizedBox(height: phonePrimaryTap, child: phoneVoiceButton(h, replyBarVoiceLabel)),
          ),
          const SizedBox(width: 12),
        ] else
          const Spacer(),
        if (onType != null)
          Semantics(
            button: true,
            label: label,
            excludeSemantics: true,
            onTap: onType,
            child: GestureDetector(
              key: const Key('composer-open'),
              behavior: HitTestBehavior.opaque,
              onTap: onType,
              child: Container(
                width: phonePrimaryTap,
                height: phonePrimaryTap,
                alignment: Alignment.center,
                decoration: t.raiseBox(),
                child: Icon(open ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined, color: t.text),
              ),
            ),
          ),
      ],
    );
  }
}
