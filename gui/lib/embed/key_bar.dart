// The key bar (iOS input toggle): Esc, Tab, arrows, ⌃ ⌥ ⌘, copy and paste over a terminal or an app session, laid out
// by [keyBarRows]. A terminal gets wire key names, an app macOS key codes. The modifiers are sticky ([ModifierLatch]);
// the arrows and ⌫ repeat while held, and an arrow swiped up sends its alt (Home, PgUp, PgDn, End). A key takes no
// focus: whatever had it keeps it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform_caps.dart';
import '../term/term_session_port.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'key_bar_keys.dart';
import 'modifier_latch.dart';
import 'phrase_strip.dart';
import 'phrases.dart';
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
      hardware: hardwareKeyboard() || lastHardwareKey != null, // sticky: once seen, the ⊙ stays
    );

/// Whether the 常用语条 tops the bar (phrases spec §2): iOS, 显示常用语条 on, the bar not ⊙ slim, some phrases,
/// and a text terminal or an app whose profile has 常用语条 on.
bool phraseStripShown(MainState state, RemoteSession session) {
  final p = state.prefs;
  return defaultTargetPlatform == TargetPlatform.iOS &&
      p.phraseStrip &&
      !p.keyBarSlim &&
      p.phrases.isNotEmpty &&
      (_isTerm(state, session) || session.profile.phrases);
}

/// How high the bar is at [width], with the modes now on (the 常用语条 included).
double keyBarHeightOf(MainState state, RemoteSession session, double width) =>
    keyBarHeight(_rowsOf(state, session, width).length) + (phraseStripShown(state, session) ? phraseStripHeight : 0);

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

/// What an app session's modifier keys send to A, by modifier bit (down and up, one key code each).
const appModifierCodes = <int, int>{latchCmd: 55, latchOpt: 58, latchCtrl: 59, latchShift: 56};

/// Keeps A's modifiers in step with a [ModifierLatch] for one app session: a down for each modifier turned on, an up
/// for each turned off, the hardware keyboard's latch told each change; and sends the plain keys with the latch.
/// [start] binds it, [stop] lets go of everything held (every down on A gets its up).
class AppKeySender {
  AppKeySender({required this.sid, required this.latch, required this.port});

  final Object sid;
  final ModifierLatch latch;
  final SessionPort? Function() port;

  /// The modifiers A was sent a down for (and has not had the up of).
  int _held = 0;

  StreamSubscription<SessionEvent>? _events;

  void start() {
    // A keyed switch builds the new bar before the old one is gone: whatever is still latched goes up for the old
    // sid first (its own listener), so this sid is never sent a stray down.
    if (latch.flags != 0) latch.releaseAll();
    _held = 0;
    latch.addListener(_sync);
    _events = port()?.events.listen(_onEvent);
    _sync();
  }

  /// The runner's key router sent a hardware key with the latch and dropped it (`latch_used`): the once modifiers go
  /// up, and the locked ones go back to the runner for the next key. Another session's is not this one's.
  void _onEvent(SessionEvent e) {
    if (e is! LatchUsedEvent || e.sid != sid) return;
    final before = latch.flags;
    latch.used(); // a change sends the new latch through _sync
    if (latch.flags == before && before != 0) port()?.latch(sid, before);
  }

  /// Every down on A gets its up: whatever the latch held goes up for the session it went down for.
  void stop() {
    _events?.cancel();
    _events = null;
    latch.releaseAll();
    _sync();
    latch.removeListener(_sync);
  }

  /// Tells A the difference between what it holds and what the latch has on: a down for each modifier turned on,
  /// an up for each turned off (each with the flags that are on after it), then the hardware keyboard's latch.
  void _sync() {
    final want = latch.flags;
    if (want == _held) return;
    final p = port();
    var on = _held;
    for (final e in appModifierCodes.entries) {
      final bit = e.key;
      if ((on & bit != 0) == (want & bit != 0)) continue;
      final down = want & bit != 0;
      on = down ? on | bit : on & ~bit;
      p?.keyEvent(sid, e.value, on, down: down);
    }
    _held = want;
    p?.latch(sid, want);
  }

  /// A plain key: [code] goes with the modifiers on, which are then used up.
  void press(int code, {int mods = 0}) {
    port()?.key(sid, code, mods | latch.flags);
    latch.used();
  }
}

class KeyBar extends StatefulWidget {
  const KeyBar(
      {super.key,
      required this.state,
      required this.session,
      required this.port,
      this.onCopy});

  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  /// The terminal stage's selection copy; null for an app (sends ⌘C).
  final VoidCallback? onCopy;

  @override
  State<KeyBar> createState() => _KeyBarState();
}

class _KeyBarState extends State<KeyBar> {
  AppKeySender? _sender;

  bool get _term => _isTerm(widget.state, widget.session);
  ModifierLatch get _latch => keyLatchOf(widget.state, widget.session);
  Object get _sid => widget.session.sid;

  /// A network drop froze the session: the keys go grey and send nothing.
  bool get _blocked => widget.state.sendBlocked(_sid);

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

  /// Sends [key] with the latch's modifiers, which are then used up; a repeat passes the [flags] of the first press
  /// and leaves the latch alone. Returns the flags it went with.
  int _send(BarKey key, int? flags) {
    final latch = _latch;
    final on = flags ?? latch.flags;
    if (_term) {
      final port = widget.port;
      if (port is! TermSessionPort) return on;
      port.sendKeys(_sid, [termWire(key.wire!, on)]);
    } else {
      widget.port.key(_sid, key.code!, key.mods | on);
    }
    if (flags == null) latch.used();
    return on;
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

  /// A key goes (down for most; up for an arrow, after its swipe was told from its hold). A press plays the click, a
  /// repeat ([haptic] false) does not. Returns the latch flags a send went with, for the repeats to keep.
  int? _fire(BarKey key, {bool alt = false, bool haptic = true, int? flags}) {
    if (_blocked) return null;
    if (haptic) unawaited(HapticFeedback.selectionClick());
    final target = alt ? barKeys[key.alt]! : key;
    switch (target.kind) {
      case BarKind.send:
        return _send(target, flags);
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
    return null;
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
          final strip = phraseStripShown(widget.state, widget.session);
          return Container(
            height: keyBarHeightOf(widget.state, widget.session, width),
            width: double.infinity,
            padding: const EdgeInsets.all(keyBarPad),
            decoration: t.floatBox(),
            child: Column(
              children: [
                if (strip) ...[
                  PhraseStrip(state: widget.state, session: widget.session, port: widget.port),
                  const SizedBox(height: phraseStripGap),
                ],
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
          blocked: _blocked,
          onFire: (alt, haptic, flags) => _fire(key, alt: alt, haptic: haptic, flags: flags),
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
  final int? Function(bool alt, bool haptic, int? flags) onFire;

  @override
  State<_BarKeyView> createState() => _BarKeyViewState();
}

class _BarKeyViewState extends State<_BarKeyView> {
  Timer? _timer;
  Offset? _from;
  bool _swiped = false, _sentByHold = false;

  /// The latch flags the first press went with: a hold repeats with them.
  int? _flags;

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
    _timer = Timer.periodic(keyRepeatEvery, (_) => widget.onFire(false, false, _flags));
  }

  void _down(PointerDownEvent e) {
    if (widget.blocked) return;
    _from = e.position;
    _swiped = _sentByHold = false;
    _flags = null;
    if (!_waits) _flags = widget.onFire(false, true, null);
    if (_k.repeats) {
      _timer = Timer(keyRepeatAfter, () {
        _sentByHold = true;
        _flags = widget.onFire(false, _waits, _flags);
        _repeat();
      });
    }
  }

  void _move(PointerMoveEvent e) {
    final from = _from;
    if (from == null || _swiped || _sentByHold || _k.alt == null) return;
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
      widget.onFire(true, true, null);
    } else if (!sentByHold) {
      widget.onFire(false, true, null);
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
      onTap: widget.blocked ? null : () => widget.onFire(false, true, null),
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
