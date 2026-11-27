// The star of 快捷区 (quick-row spec §5.4, §6.4, §7): ☆ / ★ beside an item in the two menus and on the two settings
// pages. One widget for all of them, so they look and read the same.
import 'package:flutter/material.dart';

import 'tokens.dart';

class StarButton extends StatelessWidget {
  const StarButton({super.key, required this.starred, required this.onPressed});

  final bool starred;

  /// Only toggles the star: never sends, never closes what it sits in.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return IconButton(
      tooltip: starred ? '取消星标' : '打星',
      icon: Icon(starred ? Icons.star : Icons.star_border, color: starred ? t.accent : t.muted),
      onPressed: onPressed,
    );
  }
}
