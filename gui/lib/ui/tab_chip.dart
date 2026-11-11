// Tab-style button (design language section 8): selected = --text border,
// --raise fill, weight 600; unselected = --line border, transparent.
import 'package:flutter/material.dart';

import 'tokens.dart';

class TabChip extends StatelessWidget {
  const TabChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final radius = BorderRadius.circular(t.r);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: selected
                ? t.raiseBox(border: t.text)
                : BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: t.line),
                  ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t.text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
