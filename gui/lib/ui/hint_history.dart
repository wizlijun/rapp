// The top bar's hint, right-aligned before the right-hand group, and its history: once anything
// has been said this run, a ▾ stays at the hint's right end (the line, while there is one, sits to
// its left), and a tap on either opens the list of every line, newest first.
import 'package:flutter/material.dart';

import 'corner_popover.dart';
import 'main_state.dart';
import 'tokens.dart';

class HintAnchor extends StatelessWidget {
  const HintAnchor({super.key, required this.state, this.showText = true});

  final MainState state;

  /// Whether the line itself fits; without it only the ▾ is left.
  final bool showText;

  /// The narrowest the area may be and still hold the bare line.
  static const minWidth = 26.0;

  /// The narrowest the history's button may be (a tap target, never under 48).
  static const buttonWidth = 48.0;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final text = showText ? state.hint : '';
    return LayoutBuilder(builder: (context, box) {
      if (state.hintHistory.isEmpty || box.maxWidth < buttonWidth) {
        // Nothing said yet (or no room for the button): the bare line, as before, or nothing.
        return Align(
          alignment: Alignment.centerRight,
          child: text.isEmpty || box.maxWidth < minWidth ? const SizedBox.shrink() : _line(t, text),
        );
      }
      final open = state.corner == Corner.hints;
      final radius = BorderRadius.circular(t.r);
      return Align(
        alignment: Alignment.centerRight,
        child: CornerPopover(
          open: open,
          onClose: state.closeCorner,
          scrimKey: const Key('hints-scrim'),
          popover: HintHistoryList(state: state),
          child: Semantics(
            button: true,
            selected: open,
            label: text.isEmpty ? '提示历史' : '$text，提示历史',
            excludeSemantics: true,
            onTap: () => state.toggleCorner(Corner.hints),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: const Key('hint-button'),
                onTap: () => state.toggleCorner(Corner.hints),
                borderRadius: radius,
                child: DecoratedBox(
                  decoration: open ? t.raiseBox(border: t.text) : BoxDecoration(borderRadius: radius),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: buttonWidth, minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (text.isNotEmpty) Flexible(child: _line(t, text)),
                          Icon(Icons.arrow_drop_down, key: const Key('hint-arrow'), size: 18, color: t.muted),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _line(RappTokens t, String text) => Text(
        text,
        key: const Key('hint-text'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: TextStyle(color: t.muted),
      );
}

/// `13:42:07  已打开 Xcode @ mac-mini`, newest first.
class HintHistoryList extends StatelessWidget {
  const HintHistoryList({super.key, required this.state});

  final MainState state;

  static String clock(DateTime at) =>
      [at.hour, at.minute, at.second].map((n) => n.toString().padLeft(2, '0')).join(':');

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return SingleChildScrollView(
      key: const Key('hint-history'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in state.hintHistory)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clock(r.at),
                    style: TextStyle(color: t.muted, fontFamily: t.mono, fontFamilyFallback: t.monoFallback),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(r.text)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
