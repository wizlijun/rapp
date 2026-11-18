// The app key row (iPad spec §8.3, §8.4): Esc Tab ⌘ ⌥ ⌃ ⇧ ← ↑ ↓ → 删除 回车 over an app session's picture, for the
// keys a touch screen (or the system, F14) does not give. The modifiers are sticky ([ModifierLatch]): a tap holds one
// down on A until the next key has gone (⌘ then the hardware keyboard's Tab is ⌘Tab on A), a double tap locks it.
// A tap takes no focus: the keys stay where they were.
import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'modifier_latch.dart';
import 'session_port.dart';

/// A key of the row: [code] its macOS key code; [bit] its modifier bit, null for a plain key.
typedef AppKey = ({String name, String label, String spoken, int code, int? bit});

const appKeyRowKeys = <AppKey>[
  (name: 'Esc', label: 'Esc', spoken: 'Esc', code: 53, bit: null),
  (name: 'Tab', label: 'Tab', spoken: 'Tab', code: 48, bit: null),
  (name: 'Cmd', label: '⌘', spoken: 'Command', code: 55, bit: latchCmd),
  (name: 'Opt', label: '⌥', spoken: 'Option', code: 58, bit: latchOpt),
  (name: 'Ctrl', label: '⌃', spoken: 'Control', code: 59, bit: latchCtrl),
  (name: 'Shift', label: '⇧', spoken: 'Shift', code: 56, bit: latchShift),
  (name: 'Left', label: '←', spoken: '左', code: 123, bit: null),
  (name: 'Up', label: '↑', spoken: '上', code: 126, bit: null),
  (name: 'Down', label: '↓', spoken: '下', code: 125, bit: null),
  (name: 'Right', label: '→', spoken: '右', code: 124, bit: null),
  (name: 'Delete', label: '⌫', spoken: '删除', code: 51, bit: null),
  (name: 'Return', label: '⏎', spoken: '回车', code: 36, bit: null),
];

/// What a key of the row takes on screen.
const appKeySize = Size(48, 48);
const _gap = 4.0;
const _pad = 8.0;

/// The row's whole width, all twelve keys showing; a narrower stage scrolls it.
final appKeyRowWidth = appKeyRowKeys.length * appKeySize.width + (appKeyRowKeys.length - 1) * _gap + 2 * _pad;

class AppKeyRow extends StatefulWidget {
  const AppKeyRow({super.key, required this.state, required this.sid, required this.latch});

  final MainState state;
  final Object sid;
  final ModifierLatch latch;

  @override
  State<AppKeyRow> createState() => _AppKeyRowState();
}

class _AppKeyRowState extends State<AppKeyRow> {
  late Object _sid;
  late ModifierLatch _latch;

  /// The modifiers A was sent a down for (and has not had the up of).
  int _held = 0;

  StreamSubscription<SessionEvent>? _events;

  SessionPort? get _port => widget.state.portOf(_sid);

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _sid = widget.sid;
    _latch = widget.latch;
    _held = 0;
    _latch.addListener(_sync);
    _events = _port?.events.listen(_onEvent);
    _sync();
  }

  /// The runner's key router sent a hardware key with the latch and dropped it (`latch_used`): the once modifiers go
  /// up, and the locked ones go back to the runner for the next key. Another session's is not this row's.
  void _onEvent(SessionEvent e) {
    if (e is! LatchUsedEvent || e.sid != _sid) return;
    final before = _latch.flags;
    _latch.used(); // a change sends the new latch through _sync
    if (_latch.flags == before && before != 0) _port?.latch(_sid, before);
  }

  /// Every down on A gets its up: whatever the latch held goes up for the session it went down for.
  void _unbind() {
    _events?.cancel();
    _events = null;
    _latch.releaseAll();
    _sync();
    _latch.removeListener(_sync);
  }

  @override
  void didUpdateWidget(AppKeyRow old) {
    super.didUpdateWidget(old);
    if (old.sid != widget.sid || !identical(old.latch, widget.latch)) {
      _unbind();
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  /// Tells A the difference between what it holds and what the latch has on: a down for each modifier turned on,
  /// an up for each turned off (each with the flags that are on after it), then the hardware keyboard's latch.
  void _sync() {
    final want = _latch.flags;
    if (want == _held) return;
    final port = _port;
    var on = _held;
    for (final k in appKeyRowKeys) {
      final bit = k.bit;
      if (bit == null || (on & bit != 0) == (want & bit != 0)) continue;
      final down = want & bit != 0;
      on = down ? on | bit : on & ~bit;
      port?.keyEvent(_sid, k.code, on, down: down);
    }
    _held = want;
    port?.latch(_sid, want);
  }

  void _press(AppKey k) {
    final bit = k.bit;
    if (bit != null) {
      _latch.tap(bit);
      return;
    }
    _port?.key(_sid, k.code, _latch.flags);
    _latch.used();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _latch,
        builder: (context, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(_pad),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, k) in appKeyRowKeys.indexed) ...[
                if (i > 0) const SizedBox(width: _gap),
                _Key(
                  key: Key('appkey-${k.name}'),
                  label: k.label,
                  spoken: k.spoken,
                  modifier: k.bit != null,
                  state: k.bit == null ? LatchState.off : _latch.of(k.bit!),
                  onTap: () => _press(k),
                ),
              ],
            ],
          ),
        ),
      );
}

class _Key extends StatelessWidget {
  const _Key(
      {super.key,
      required this.label,
      required this.spoken,
      required this.modifier,
      required this.state,
      required this.onTap});
  final String label;
  final String spoken;
  final bool modifier;
  final LatchState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final once = state == LatchState.once, locked = state == LatchState.locked;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(t.r),
      side: BorderSide(color: once || locked ? t.accent : t.line, width: once || locked ? 2 : 1),
    );
    return Semantics(
      button: true,
      label: spoken,
      toggled: modifier ? state != LatchState.off : null,
      excludeSemantics: true,
      onTap: onTap,
      child: SizedBox.fromSize(
        size: appKeySize,
        child: Material(
          // Locked adds a faint accent fill to the border it shares with once, so the two read apart.
          color: locked ? Color.alphaBlend(t.accent.withValues(alpha: .18), t.raise.first) : t.raise.first,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          // Never focusable: a tap leaves the keys where they were.
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: Center(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13, color: t.text, fontFamily: t.mono, fontFamilyFallback: t.monoFallback)),
            ),
          ),
        ),
      ),
    );
  }
}
