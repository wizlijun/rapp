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
    this.leading,
    this.onSecondaryTap,
    this.onClose,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Optional decorative widget (a status lamp) before the label.
  final Widget? leading;

  /// Right-click (secondary tap up) at a global position.
  final void Function(Offset globalPosition)? onSecondaryTap;

  /// A × after the label (closes what the tab stands for); none when null.
  final VoidCallback? onClose;

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
          onSecondaryTapUp: onSecondaryTap == null ? null : (d) => onSecondaryTap!(d.globalPosition),
          borderRadius: radius,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            alignment: Alignment.center,
            padding: EdgeInsets.only(left: 12, right: onClose == null ? 12 : 2),
            decoration: selected
                ? t.raiseBox(border: t.text)
                : BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: t.line),
                  ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 8)],
                Flexible(
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
                if (onClose != null)
                  Semantics(
                    button: true,
                    label: '关闭 $label',
                    excludeSemantics: true,
                    onTap: onClose,
                    child: InkResponse(
                      key: const Key('tab-close'),
                      onTap: onClose,
                      radius: 16,
                      child: SizedBox(
                        width: 32,
                        height: 40,
                        child: Icon(Icons.close, size: 16, color: t.text),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
