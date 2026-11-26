// A group title in a session list (the side panel's 会话 tab, the top bar's list); the sessions in it are
// [SessionBlock]s.
import 'package:flutter/material.dart';

import 'tokens.dart';

class SessionGroupTitle extends StatelessWidget {
  const SessionGroupTitle(this.title, {super.key, this.onTap});
  final String title;

  /// A project's name is a button (切到); the other titles are plain text.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final text = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: t.muted, letterSpacing: t.textSize * t.labelSpacing),
    );
    if (onTap == null) {
      return Padding(padding: const EdgeInsets.fromLTRB(2, 10, 2, 6), child: text);
    }
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.centerLeft,
          child: text,
        ),
      ),
    );
  }
}
