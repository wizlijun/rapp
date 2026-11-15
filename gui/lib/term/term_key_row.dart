// The key row (G5, W3): six big keys on a terminal's stage, so it can be interrupted and driven without a keyboard.
// Esc ⌃C Tab at the left, ↑ ↓ ⏎ at the right. A tap sends the key to the pane being viewed and takes no focus:
// the caret stays where it was, in the writing panel or on the stage.
import 'package:flutter/material.dart';

import '../ui/tokens.dart';
import 'term_session_port.dart';

/// A stage at least this wide has the row on the writing panel's line; a narrower one puts it on a line of its own
/// right above the open panel.
const keyRowWideAt = 1100.0;

/// What a key of the row takes on screen.
const keyRowKeySize = Size(52, 48);

/// Between two keys of a group.
const keyRowGap = 4.0;

/// One group of three keys, end to end.
const keyRowGroupWidth = 3 * 52.0 + 2 * keyRowGap;

/// The row's distance from the stage's sides and bottom (on the panel's line: level with the panel's box).
const keyRowInset = 12.0;
const keyRowBottom = 9.0;

/// How much further the picture moves up while the row has a line of its own above the panel (48 and a gap of 8).
const keyRowLift = 56.0;

/// (label, key name) of the left group and the right one.
const keyRowLeft = [('Esc', 'Esc'), ('⌃C', 'Ctrl-C'), ('Tab', 'Tab')];
const keyRowRight = [('↑', 'Up'), ('↓', 'Down'), ('⏎', 'Enter')];

class TermKeyRow extends StatelessWidget {
  const TermKeyRow({super.key, required this.port, required this.sid, required this.split});

  final TermSessionPort port;
  final Object sid;

  /// True: on the panel's line at the stage's bottom, the groups at the stage's two corners and the middle left to
  /// the panel or 「输入」 (and to the picture: it takes no taps there). False: a line of its own right above the open
  /// panel, as wide as the panel, the groups at its two ends.
  final bool split;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        _group(context, keyRowLeft),
        const Spacer(),
        _group(context, keyRowRight),
      ],
    );
    return Padding(
      padding: split
          ? const EdgeInsets.fromLTRB(keyRowInset, 0, keyRowInset, keyRowBottom)
          : EdgeInsets.only(bottom: keyRowLift - keyRowKeySize.height),
      child: row,
    );
  }

  Widget _group(BuildContext context, List<(String, String)> keys) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, (label, name)) in keys.indexed) ...[
            if (i > 0) const SizedBox(width: keyRowGap),
            _Key(key: Key('keyrow-$name'), label: label, onTap: () => port.sendKeys(sid, [name])),
          ],
        ],
      );
}

class _Key extends StatelessWidget {
  const _Key({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.r), side: BorderSide(color: t.line));
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: SizedBox.fromSize(
        size: keyRowKeySize,
        child: Material(
          color: t.raise.first,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          // Never focusable: a tap leaves the caret where it was.
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: Center(
              child: Text(label, style: TextStyle(color: t.text, fontFamily: t.mono, fontFamilyFallback: t.monoFallback)),
            ),
          ),
        ),
      ),
    );
  }
}
