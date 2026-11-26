// The top bar's hint, right-aligned before the right-hand group, and the status queue behind it: once
// anything has been said or any program changed state this run, a ▾ stays at the hint's right end (the
// line, while there is one, sits to its left), and a tap on either opens the queue, newest first: what
// rApp said, and what programs on the devices reported. A line about a session goes to it on a tap.
import 'package:flutter/material.dart';

import 'corner_popover.dart';
import 'lamp.dart';
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
      if (state.queueRows.isEmpty || box.maxWidth < buttonWidth) {
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
            label: text.isEmpty ? '提示和状态' : '$text，提示和状态',
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

/// `13:42:07  已打开 Xcode @ mac-mini`, newest first; a program's line has its lamp and goes to its session.
class HintHistoryList extends StatelessWidget {
  const HintHistoryList({super.key, required this.state});

  final MainState state;

  static String clock(DateTime at) =>
      [at.hour, at.minute, at.second].map((n) => n.toString().padLeft(2, '0')).join(':');

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final records = state.queueRows;
    return SingleChildScrollView(
      key: const Key('hint-history'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (var i = 0; i < records.length; i++) _row(t, records[i], i)],
      ),
    );
  }

  Widget _row(RappTokens t, HintRecord r, int i) {
    final word = r.goes ? state.offlineWord(r.device!, r.app!) : null;
    final fresh = state.queuedFresh(r);
    final line = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            clock(r.at),
            style: TextStyle(color: t.muted, fontFamily: t.mono, fontFamilyFallback: t.monoFallback),
          ),
          const SizedBox(width: 12),
          if (r.lamp != null) ...[
            Padding(padding: const EdgeInsets.only(top: 3), child: StatusLamp(r.lamp!, size: 12)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              word == null ? r.text : '${r.text} · $word',
              style: TextStyle(
                color: word == null ? null : t.muted,
                fontWeight: fresh ? FontWeight.w600 : null,
              ),
            ),
          ),
          if (r.inferred) ...[
            const SizedBox(width: 8),
            Text('推断', style: TextStyle(color: t.muted)),
          ],
        ],
      ),
    );
    if (!r.goes || word != null) return line;
    return Semantics(
      button: true,
      label: '${clock(r.at)} ${r.text}${r.inferred ? '，推断' : ''}${fresh ? '，新' : ''}',
      excludeSemantics: true,
      onTap: () => state.goToQueued(r),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('queue-$i'),
          onTap: () => state.goToQueued(r),
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: line),
        ),
      ),
    );
  }
}
