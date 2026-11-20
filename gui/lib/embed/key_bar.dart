// The key bar (iOS input toggle): Esc, Tab, arrows, ⌃ ⌥ ⌘, copy and paste over a terminal or an app session, laid out
// by [keyBarRows]. A terminal gets wire key names, an app macOS key codes. The modifiers are sticky ([ModifierLatch]);
// the arrows and ⌫ repeat while held, and an arrow swiped up sends its alt (Home, PgUp, PgDn, End). A key takes no
// focus: whatever had it keeps it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform_caps.dart';
import '../term/term_session_port.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'app_key_row.dart';
import 'key_bar_keys.dart';
import 'modifier_latch.dart';
import 'remote_session.dart';
import 'session_port.dart';

/// A repeating key starts repeating after this long held, then goes every [repeatEvery].
const keyRepeatAfter = Duration(milliseconds: 400);
const keyRepeatEvery = Duration(milliseconds: 80);

/// A swipe up this far (logical points) on a key with an alt sends the alt.
const keySwipeUp = 24.0;

bool _isTerm(MainState state, RemoteSession session) => state.termPort?.owns(session.sid) == true;

/// The sticky modifiers the bar and the hardware keys of [session] share: a terminal's own, the state's for an app.
ModifierLatch keyLatchOf(MainState state, RemoteSession session) =>
    _isTerm(state, session) ? session.keyLatch : state.appLatch;

List<List<String?>> _rowsOf(MainState state, RemoteSession session, double width) => keyBarRows(
      width: width,
      app: !_isTerm(state, session),
      more: state.prefs.keyBarMore,
      slim: state.prefs.keyBarSlim,
      hardware: hardwareKeyboard(),
    );

/// How high the bar is at [width], with the modes now on.
double keyBarHeightOf(MainState state, RemoteSession session, double width) =>
    keyBarHeight(_rowsOf(state, session, width).length);

/// A terminal's wire name for [wire] with the latch's ⌃ and ⌥ added, in the wire's order `[Ctrl-][Alt-][Shift-]base`.
String termWire(String wire, int flags) {
  final parts = wire.split('-');
  final base = parts.last, has = parts.take(parts.length - 1).toSet();
  final ctrl = flags & latchCtrl != 0 || has.contains('Ctrl');
  final alt = flags & latchOpt != 0 || has.contains('Alt');
  final shift = flags & latchShift != 0 || has.contains('Shift');
  return '${ctrl ? 'Ctrl-' : ''}${alt ? 'Alt-' : ''}${shift ? 'Shift-' : ''}$base';
}

/// A typed [letter] with ⌃ / ⌥ / ⌘ latched goes out with them and the latch is used up: true. Nothing latched: false
/// and nothing sent. A terminal takes `Ctrl-R` / `Alt-r`; an app the macOS key code of the letter and the flags.
bool sendLatchedLetter(MainState state, RemoteSession session, SessionPort port, String letter) {
  final latch = keyLatchOf(state, session);
  final flags = latch.flags;
  if (_isTerm(state, session)) {
    if (flags & (latchCtrl | latchOpt) == 0 || port is! TermSessionPort) return false;
    final ctrl = flags & latchCtrl != 0;
    port.sendKeys(session.sid, [termWire(ctrl ? letter.toUpperCase() : letter, flags)]);
  } else {
    final code = macLetterCodes[letter.toLowerCase()];
    if (flags & (latchCtrl | latchOpt | latchCmd) == 0 || code == null) return false;
    port.key(session.sid, code, flags);
  }
  latch.used();
  return true;
}

class KeyBar extends StatefulWidget {
  const KeyBar(
      {super.key,
      required this.state,
      required this.session,
      required this.port,
      this.onCopy,
      this.blocked = false});

  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  /// The terminal stage's selection copy; null for an app (sends ⌘C).
  final VoidCallback? onCopy;

  /// A network drop froze the session: the keys go grey and send nothing.
  final bool blocked;

  @override
  State<KeyBar> createState() => _KeyBarState();
}

class _KeyBarState extends State<KeyBar> {
  AppKeySender? _sender;

  bool get _term => _isTerm(widget.state, widget.session);
  ModifierLatch get _latch => keyLatchOf(widget.state, widget.session);
  Object get _sid => widget.session.sid;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    if (_term) return;
    final sid = _sid, p = widget.port;
    _sender = AppKeySender(sid: sid, latch: _latch, port: () => p)..start();
  }

  void _unbind() {
    _sender?.stop();
    _sender = null;
  }

  @override
  void didUpdateWidget(KeyBar old) {
    super.didUpdateWidget(old);
    if (old.session.sid != widget.session.sid || !identical(old.port, widget.port)) {
      _unbind();
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  void _send(BarKey key) {
    final latch = _latch;
    if (_term) {
      final port = widget.port;
      if (port is! TermSessionPort) return;
      port.sendKeys(_sid, [termWire(key.wire!, latch.flags)]);
      latch.used();
    } else {
      _sender?.press(key.code!, mods: key.mods);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    final port = widget.port;
    if (port is TermSessionPort && _term) {
      port.paste(_sid, text);
    } else {
      port.composerSend(_sid, [
        {'text': text},
      ]);
    }
  }

  /// A key goes (down for most; up for an arrow, after its swipe was told from its hold).
  void _fire(BarKey key, {bool alt = false}) {
    if (widget.blocked) return;
    final target = alt ? barKeys[key.alt]! : key;
    switch (target.kind) {
      case BarKind.send:
        _send(target);
      case BarKind.mod:
        _latch.tap(target.bit!);
      case BarKind.copy:
        final copy = widget.onCopy;
        if (copy != null) {
          copy();
        } else {
          widget.port.key(_sid, 8, latchCmd);
        }
      case BarKind.paste:
        _paste();
      case BarKind.more:
        widget.state.setKeyBarMore(!widget.state.prefs.keyBarMore);
      case BarKind.slim:
        widget.state.setKeyBarSlim(!widget.state.prefs.keyBarSlim);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      return ListenableBuilder(
        listenable: Listenable.merge([widget.state, _latch]),
        builder: (context, _) {
          final rows = _rowsOf(widget.state, widget.session, width);
          return Container(
            height: keyBarHeight(rows.length),
            width: double.infinity,
            padding: const EdgeInsets.all(keyBarPad),
            decoration: t.floatBox(),
            child: Column(
              children: [
                for (final (i, row) in rows.indexed) ...[
                  if (i > 0) const SizedBox(height: keyBarGap),
                  Expanded(child: _rowOf(row)),
                ],
              ],
            ),
          );
        },
      );
    });
  }

  Widget _rowOf(List<String?> ids) {
    final children = <Widget>[];
    for (final (i, id) in ids.indexed) {
      if (id == null) {
        children.add(const SizedBox(width: keyBarGroupGap));
        continue;
      }
      if (i > 0 && ids[i - 1] != null) children.add(const SizedBox(width: keyBarGap));
      final key = barKeys[id]!;
      children.add(Expanded(
        child: _BarKeyView(
          key: Key('bar-$id'),
          keyDef: key,
          sid: _sid,
          state: key.bit == null ? LatchState.off : _latch.of(key.bit!),
          blocked: widget.blocked,
          onFire: (alt) => _fire(key, alt: alt),
        ),
      ));
    }
    return Row(children: children);
  }
}

class _BarKeyView extends StatefulWidget {
  const _BarKeyView(
      {super.key,
      required this.keyDef,
      required this.sid,
      required this.state,
      required this.blocked,
      required this.onFire});
  final BarKey keyDef;
  final Object sid;
  final LatchState state;
  final bool blocked;
  final void Function(bool alt) onFire;

  @override
  State<_BarKeyView> createState() => _BarKeyViewState();
}

class _BarKeyViewState extends State<_BarKeyView> {
  Timer? _timer;
  Offset? _from;
  bool _swiped = false, _sentByHold = false;

  BarKey get _k => widget.keyDef;

  /// A key with an alt waits for its finger to say tap, swipe or hold; the rest go at once.
  bool get _waits => _k.alt != null;

  @override
  void didUpdateWidget(_BarKeyView old) {
    super.didUpdateWidget(old);
    if (old.sid != widget.sid || widget.blocked) _stop();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _from = null;
  }

  void _repeat() {
    _timer = Timer.periodic(keyRepeatEvery, (_) => widget.onFire(false));
  }

  void _down(PointerDownEvent e) {
    if (widget.blocked) return;
    _from = e.position;
    _swiped = _sentByHold = false;
    if (!_waits) widget.onFire(false);
    if (_k.repeats) {
      _timer = Timer(keyRepeatAfter, () {
        _sentByHold = true;
        widget.onFire(false);
        _repeat();
      });
    }
  }

  void _move(PointerMoveEvent e) {
    final from = _from;
    if (from == null || _swiped || _k.alt == null) return;
    if (from.dy - e.position.dy >= keySwipeUp) {
      _swiped = true;
      _timer?.cancel();
      _timer = null;
    }
  }

  void _up(PointerUpEvent e) {
    final held = _from != null;
    final swiped = _swiped, sentByHold = _sentByHold;
    _stop();
    if (!held || !_waits) return;
    if (swiped) {
      widget.onFire(true);
    } else if (!sentByHold) {
      widget.onFire(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final k = _k;
    final once = widget.state == LatchState.once, locked = widget.state == LatchState.locked;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(t.r),
      side: BorderSide(color: once || locked ? t.accent : t.line, width: once || locked ? 2 : 1),
    );
    final alt = k.alt == null ? null : barKeys[k.alt]!;
    return Semantics(
      button: true,
      label: k.spoken,
      toggled: k.bit != null ? widget.state != LatchState.off : null,
      excludeSemantics: true,
      onTap: widget.blocked ? null : () => widget.onFire(false),
      child: Opacity(
        opacity: widget.blocked ? .4 : 1,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: (_) => _stop(),
          child: Material(
            color: locked ? Color.alphaBlend(t.accent.withValues(alpha: .18), t.raise.first) : t.raise.first,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            // Never focusable: a tap leaves the caret where it was.
            child: InkWell(
              canRequestFocus: false,
              onTap: widget.blocked ? null : () {},
              child: Stack(
                children: [
                  Center(
                    child: Text(k.label,
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 13, color: t.text, fontFamily: t.mono, fontFamilyFallback: t.monoFallback)),
                  ),
                  if (alt != null)
                    Positioned(
                      top: 2,
                      right: 3,
                      child: Text(alt.label, style: TextStyle(fontSize: 9, color: t.muted)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
