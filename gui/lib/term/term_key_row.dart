// The key row (G5, W3): six big keys on a terminal's stage, so it can be interrupted and driven without a keyboard.
// ⌃ Esc ⌃C Tab at the left, ↑ ↓ ⏎ at the right. ⌃ is sticky: the next key (one of the row's, or the keyboard's on
// the stage) goes with Ctrl, a letter as `Ctrl-<letter>`, anything else as it is; then the ⌃ goes out. A tap sends
// the key to the pane being viewed and takes no focus: the caret stays where it was, in the writing panel or on the
// stage.
import 'package:flutter/material.dart';

import '../ui/tokens.dart';
import 'term_session_port.dart';

/// What a key of the row takes on screen.
const keyRowKeySize = Size(52, 48);

/// Between two keys of a group.
const keyRowGap = 4.0;

/// The right group (↑ ↓ ⏎), end to end.
const keyRowGroupWidth = 3 * 52.0 + 2 * keyRowGap;

/// The left group (⌃ Esc ⌃C Tab), end to end.
const keyRowLeftWidth = 4 * 52.0 + 3 * keyRowGap;

/// The row's distance from the stage's sides and bottom (on the panel's line: level with the panel's box).
const keyRowInset = 12.0;
const keyRowBottom = 9.0;

/// The open terminal panel's width on a wide stage ([panelWidth] at scale 1).
const _panelWide = 720.0;

/// Between a corner group and the open panel on the panel's line.
const _clear = 8.0;

/// A stage at least this wide has the row on the writing panel's line; a narrower one puts it on a line of its own
/// right above the open panel. Derived from the wider (left) group, so the centred panel never covers it.
const keyRowWideAt = 2 * (keyRowInset + keyRowLeftWidth + _clear) + _panelWide;

/// How much further the picture moves up while the row has a line of its own above the panel (48 and a gap of 8).
const keyRowLift = 56.0;

/// (label, key name) of the left group and the right one.
const keyRowLeft = [('Esc', 'Esc'), ('⌃C', 'Ctrl-C'), ('Tab', 'Tab')];
const keyRowRight = [('↑', 'Up'), ('↓', 'Down'), ('⏎', 'Enter')];

class TermKeyRow extends StatelessWidget {
  const TermKeyRow(
      {super.key,
      required this.port,
      required this.sid,
      required this.ctrl,
      required this.split,
      this.blocked = false});

  final TermSessionPort port;
  final Object sid;

  /// The sticky ⌃, the session's ([RemoteSession.termCtrl]): the terminal stage reads it for the keyboard's keys.
  final ValueNotifier<bool> ctrl;

  /// True: on the panel's line at the stage's bottom, the groups at the stage's two corners and the middle left to
  /// the panel or 「输入」 (and to the picture: it takes no taps there). False: a line of its own right above the open
  /// panel, as wide as the panel, the groups at its two ends.
  final bool split;

  /// A network drop froze the session: the keys go grey and send nothing.
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          ValueListenableBuilder<bool>(
            valueListenable: ctrl,
            builder: (context, on, _) => _Key(
              key: const Key('keyrow-Ctrl'),
              label: '⌃',
              lit: on,
              onTap: blocked ? null : () => ctrl.value = !ctrl.value,
            ),
          ),
          const SizedBox(width: keyRowGap),
          _group(context, keyRowLeft),
        ]),
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

  /// A key of the row has no letter: it goes as it is, and a lit ⌃ goes out with it.
  void _send(String name) {
    ctrl.value = false;
    port.sendKeys(sid, [name]);
  }

  Widget _group(BuildContext context, List<(String, String)> keys) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, (label, name)) in keys.indexed) ...[
            if (i > 0) const SizedBox(width: keyRowGap),
            _Key(key: Key('keyrow-$name'), label: label, onTap: blocked ? null : () => _send(name)),
          ],
        ],
      );
}

class _Key extends StatelessWidget {
  const _Key({super.key, required this.label, required this.onTap, this.lit});
  final String label;
  final VoidCallback? onTap;

  /// A sticky key's state (null for a plain key); on is outlined in the accent.
  final bool? lit;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.r),
        side: lit == true ? BorderSide(color: t.accent, width: 2) : BorderSide(color: t.line));
    return Semantics(
      button: true,
      label: label,
      toggled: lit,
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
              child: Text(label, style: TextStyle(fontSize: 13, color: onTap == null ? t.muted : t.text, fontFamily: t.mono, fontFamilyFallback: t.monoFallback)),
            ),
          ),
        ),
      ),
    );
  }
}
