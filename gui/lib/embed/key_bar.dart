// The key bar (iOS input toggle; the desktop's too, pc-key-bar spec): Esc, Tab, arrows, ⌃ ⌥ ⌘, copy and paste over a terminal or an app session, laid out
// by [keyBarRows]. A terminal gets wire key names, an app macOS key codes. The modifiers are sticky ([ModifierLatch]);
// the arrows and ⌫ repeat while held. A key takes no focus: whatever had it keeps it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../term/term_session_port.dart';
import '../ui/main_state.dart';
import '../ui/terms_entry.dart' show terminalApps;
import '../ui/tokens.dart';
import 'key_bar_keys.dart';
import 'modifier_latch.dart';
import 'phrase_strip.dart';
import 'composer_panel.dart' show seeThroughBox;
import 'phrases.dart';
import 'remote_session.dart';
import 'session_port.dart';

/// A repeating key starts repeating after this long held, then goes every [repeatEvery].
const keyRepeatAfter = Duration(milliseconds: 400);
const keyRepeatEvery = Duration(milliseconds: 80);

bool _isTerm(MainState state, RemoteSession session) => state.termPort?.owns(session.sid) == true;

/// The sticky modifiers the bar and the hardware keys of [session] share: a terminal's own, the state's for an app.
ModifierLatch keyLatchOf(MainState state, RemoteSession session) =>
    _isTerm(state, session) ? session.keyLatch : state.appLatch;

List<List<String>> _rowsOf(MainState state, RemoteSession session) =>
    keyBarRows(layout: state.quick.layout, more: state.prefs.keyBarMore);

/// Whether [session] is of the terminal kind: a text terminal or a terminal app. The kind picks which quick-area
/// pref it follows.
bool termKind(MainState state, RemoteSession session) => _isTerm(state, session) || terminalApps.contains(session.appId);

/// Whether the 快捷区 is folded for [session]'s kind.
bool quickHidden(MainState state, RemoteSession session) =>
    termKind(state, session) ? state.prefs.quickHiddenTerm : state.prefs.quickHiddenApp;

/// Key [e] typed into the picture: the picture has the keys and the writing panel's editor does not. An app's
/// picture (a terminal app's too) has them as [MainState.pictureFocused]; a text terminal's stage by its own Focus
/// ([RemoteSession.termTakesKey]), since [MainState.focusPicture] leaves pictureFocused alone for a terminal. A key
/// that belongs to a voice hold — any key during a mouse hold on 语音, and on a terminal the hotkey's own down and
/// every key while its hold runs — is the hold's, and the quick area stays as it was (spec §5.6).
bool typedIntoPicture(MainState state, RemoteSession session, KeyEvent e) =>
    (state.pictureFocused == session.sid || (session.termTakesKey?.call(e) ?? false)) &&
    !session.composer.editorFocused &&
    state.voiceMouseHold != session.sid;

/// Whether the 常用语条 tops the bar (phrases spec §2, quick-row spec §5.1): 显示常用语条 on, and a text terminal or an
/// app whose profile has 常用语条 on. It need not have a chip to show: its two menus are of use alone. Whether the quick
/// area is folded is not its business.
bool phraseStripShown(MainState state, RemoteSession session) =>
    state.prefs.phraseStrip && (_isTerm(state, session) || session.profile.phrases);

/// How high the bar is, with the modes now on (the 常用语条 included).
double keyBarHeightOf(MainState state, RemoteSession session) =>
    keyBarHeight(_rowsOf(state, session).length) + (phraseStripShown(state, session) ? phraseStripHeight : 0);

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
/// A terminal with ⌘ latched (⌃ too or not) sends nothing: ⌘ and the letter is rApp's shortcut, run by the stage
/// ([RemoteSession.termCommand]) as a hardware ⌘ would be; a letter with none does nothing, and ⌘ is used up.
bool sendLatchedLetter(MainState state, RemoteSession session, SessionPort port, String letter) {
  final latch = keyLatchOf(state, session);
  final flags = latch.flags;
  if (_isTerm(state, session)) {
    if (flags & latchCmd != 0) {
      latch.used();
      session.termCommand?.call(letter.toLowerCase());
      return true;
    }
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

final _modifierKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight, LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight, LogicalKeyboardKey.capsLock, LogicalKeyboardKey.fn,
  LogicalKeyboardKey.fnLock, LogicalKeyboardKey.shift, LogicalKeyboardKey.control, LogicalKeyboardKey.alt,
  LogicalKeyboardKey.meta, LogicalKeyboardKey.superKey, LogicalKeyboardKey.hyper, LogicalKeyboardKey.altGraph,
  LogicalKeyboardKey.numLock, LogicalKeyboardKey.scrollLock,
};

/// The desktop's "used the keyboard" (pc-key-bar spec §3): a key going down that is not a modifier, with ⌘ / Super not
/// held (⌘Tab and the app's shortcuts leave the bar as it is), nor Ctrl on Linux, whose app shortcuts are Ctrl ones.
/// A repeat or a release is not one.
bool collapsesKeyBar(KeyEvent e) =>
    e is KeyDownEvent &&
    !_modifierKeys.contains(e.logicalKey) &&
    !HardwareKeyboard.instance.isMetaPressed &&
    !(defaultTargetPlatform == TargetPlatform.linux && HardwareKeyboard.instance.isControlPressed);

/// Folds the 快捷区 of [session]'s kind: a key was typed into the picture. Not with 打字后自动收起 off, not when it is
/// folded already, and not while a ⌃ ⌥ ⌘ ⇧ on the bar is lit: folding would hide a modifier A may still hold down; the
/// next key after it goes folds.
void foldKeyBar(MainState state, RemoteSession session) {
  if (!state.quickAutoHide || quickHidden(state, session) || keyLatchOf(state, session).flags != 0) return;
  state.setQuickHidden(term: termKind(state, session), hidden: true);
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
  StreamSubscription<SessionEvent>? _typed;

  bool get _term => _isTerm(widget.state, widget.session);
  ModifierLatch get _latch => keyLatchOf(widget.state, widget.session);
  Object get _sid => widget.session.sid;

  /// A network drop froze the session: the keys go grey and send nothing.
  bool get _blocked => widget.state.sendBlocked(_sid);

  @override
  void initState() {
    super.initState();
    _bind();
    // A key typed into the picture folds the 快捷区 (打字后自动收起); the toggle beside 输入 (收起) shows it again.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  bool _onKey(KeyEvent e) {
    if (collapsesKeyBar(e) && typedIntoPicture(widget.state, widget.session, e)) foldKeyBar(widget.state, widget.session);
    return false; // only watching: the key goes on
  }

  /// macOS: a key typed into the picture goes to A without passing Flutter; the runner says so (`key_typed`).
  void _onTyped(SessionEvent e) {
    if (e is KeyTypedEvent && e.sid == _sid) foldKeyBar(widget.state, widget.session);
  }

  void _bind() {
    if (defaultTargetPlatform == TargetPlatform.macOS) _typed = widget.port.events.listen(_onTyped);
    if (_term) return;
    final sid = _sid, p = widget.port;
    _sender = AppKeySender(sid: sid, latch: _latch, port: () => p)..start();
  }

  void _unbind() {
    _typed?.cancel();
    _typed = null;
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
    HardwareKeyboard.instance.removeHandler(_onKey);
    _unbind();
    super.dispose();
  }

  /// Sends [key] with the latch's modifiers, which are then used up; a repeat passes the [flags] of the first press
  /// and leaves the latch alone. Returns the flags it went with.
  int _send(BarKey key, int? flags) {
    final latch = _latch;
    final on = flags ?? latch.flags;
    if (_term) {
      // PgUp / PgDn with nothing latched page the stage's own history; in a full-screen program they are its keys.
      if (on == 0 && (key.wire == 'PageUp' || key.wire == 'PageDown')) {
        if (widget.session.termPage?.call(key.wire == 'PageUp') ?? false) return 0;
      }
      final port = widget.port;
      if (port is! TermSessionPort) return on;
      port.sendKeys(_sid, [termWire(key.wire!, on)]);
      widget.session.termSent?.call();
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
      widget.session.termSent?.call();
    } else {
      port.composerSend(_sid, [
        {'text': text},
      ]);
    }
  }

  /// A key goes on its press. A press plays the click, a repeat ([haptic] false) does not. Returns the latch flags a
  /// send went with, for the repeats to keep.
  int? _fire(BarKey key, {bool haptic = true, int? flags}) {
    if (_blocked) return null;
    if (haptic) unawaited(HapticFeedback.selectionClick());
    switch (key.kind) {
      case BarKind.send:
        return _send(key, flags);
      case BarKind.mod:
        _latch.tap(key.bit!);
      case BarKind.copy:
        final copy = widget.onCopy;
        if (copy != null) {
          copy();
        } else {
          widget.port.key(_sid, 8, latchCmd);
        }
      case BarKind.paste:
        _paste();
      case BarKind.cmdT:
        // A terminal: the stage's own ⌘T (a new terminal beside). An app: ⌘T goes to it.
        if (_term) {
          widget.session.termCommand?.call('t');
        } else {
          widget.port.key(_sid, macLetterCodes['t']!, latchCmd);
        }
      case BarKind.more:
        // Folding the second row takes its sticky ⌃ ⌘ with it ([MainState.setKeyBarMore]); this session's too, in
        // case it is not in the session list.
        final more = widget.state.prefs.keyBarMore;
        if (more) _latch.releaseAll();
        widget.state.setKeyBarMore(!more);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return TextFieldTapRegion(
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.state, _latch]),
        builder: (context, _) {
          final rows = _rowsOf(widget.state, widget.session);
          final strip = phraseStripShown(widget.state, widget.session);
          return Container(
            height: keyBarHeightOf(widget.state, widget.session),
            width: double.infinity,
            padding: const EdgeInsets.all(keyBarPad),
            decoration: seeThroughBox(t),
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
      ),
    );
  }

  Widget _rowOf(List<String> ids) => KeyBarRow(ids: ids, cell: _cellOf);

  Widget? _cellOf(String id) {
    final key = barKeys[id];
    if (key == null) return null; // an id nothing knows (cleaned layouts have none): draw nothing rather than crash
    return _BarKeyView(
      key: Key('bar-$id'),
      keyDef: key,
      sid: _sid,
      state: key.bit == null ? LatchState.off : _latch.of(key.bit!),
      blocked: _blocked,
      onFire: (haptic, flags) => _fire(key, haptic: haptic, flags: flags),
    );
  }
}

/// One row of the bar: the arrow block at its end ([keyBarTail]) one column of [keyBarColumns] each, the keys before it
/// sharing the rest, so the arrows line up across the rows. [cell] draws one id (null: nothing). The key settings page
/// draws its layout editor with the same row, so the widths are the bar's.
class KeyBarRow extends StatelessWidget {
  const KeyBarRow({super.key, required this.ids, required this.cell});
  final List<String> ids;
  final Widget? Function(String id) cell;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final column = ((c.maxWidth - (keyBarColumns - 1) * keyBarGap) / keyBarColumns).clamp(0.0, double.infinity);
      final tail = keyBarTail(ids);
      // A row made of the arrow block alone has nothing to share the rest: an empty cell holds the columns at the right.
      final children = <Widget>[if (ids.isNotEmpty && tail == ids.length) const Expanded(child: SizedBox())];
      for (final (i, id) in ids.indexed) {
        final view = cell(id);
        if (view == null) continue;
        if (children.isNotEmpty) children.add(const SizedBox(width: keyBarGap));
        children.add(i >= ids.length - tail ? SizedBox(width: column, child: view) : Expanded(child: view));
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    });
  }
}

/// A face that is one symbol (⏎ ⌫ ↑ ⌘ ⋯), not a word or a chord like ⌃C: drawn bigger, the way a keycap prints it.
bool isSymbolKeyLabel(String label) =>
    label.runes.length == 1 && !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(label);

/// Each platform's own UI font for key faces, so ⏎ ⌫ ↑ look like that platform's keyboard: SF Pro on Apple, Segoe UI
/// on Windows, Roboto on Android, the system sans on Linux, each with the symbol fonts the platform ships behind it.
/// Never the mono font: SF Mono and Menlo draw these arrows small and thin.
TextStyle keyFaceStyle(TargetPlatform platform, String label) {
  final (family, fallback) = switch (platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => ('CupertinoSystemText', const ['Apple Symbols']),
    TargetPlatform.windows => ('Segoe UI', const ['Segoe UI Symbol', 'Segoe UI Emoji']),
    TargetPlatform.android => ('Roboto', const ['Noto Sans Symbols', 'Noto Sans Symbols 2']),
    TargetPlatform.linux || TargetPlatform.fuchsia =>
      ('sans-serif', const ['DejaVu Sans', 'Noto Sans', 'Noto Sans Symbols', 'Noto Sans Symbols 2']),
  };
  return TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: isSymbolKeyLabel(label) ? 19 : 14,
    fontWeight: FontWeight.w500,
  );
}

/// The face of a key: a rounded box with its [label]; [lit] draws the accent border (a lit modifier, or a selected cell
/// in the layout editor), [locked] also tints it. Never focusable: a tap leaves the caret where it was.
class KeyFace extends StatelessWidget {
  const KeyFace({super.key, required this.label, this.lit = false, this.locked = false, this.onTap});
  final String label;
  final bool lit;
  final bool locked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final accent = lit || locked;
    return Material(
      color: locked ? Color.alphaBlend(t.accent.withValues(alpha: .18), t.raise.first) : t.raise.first,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.r),
        side: BorderSide(color: accent ? t.accent : t.line, width: accent ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        canRequestFocus: false,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  maxLines: 1,
                  softWrap: false,
                  style: keyFaceStyle(Theme.of(context).platform, label).copyWith(color: t.text)),
            ),
          ),
        ),
      ),
    );
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
  final int? Function(bool haptic, int? flags) onFire;

  @override
  State<_BarKeyView> createState() => _BarKeyViewState();
}

class _BarKeyViewState extends State<_BarKeyView> {
  Timer? _timer;

  /// The latch flags the first press went with: a hold repeats with them.
  int? _flags;

  BarKey get _k => widget.keyDef;

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
  }

  /// A key goes at once; a repeating one goes again after [keyRepeatAfter] held, then every [keyRepeatEvery].
  void _down(PointerDownEvent e) {
    if (widget.blocked) return;
    _stop();
    _flags = widget.onFire(true, null);
    if (!_k.repeats) return;
    _timer = Timer(keyRepeatAfter, () {
      _flags = widget.onFire(false, _flags);
      _timer = Timer.periodic(keyRepeatEvery, (_) => widget.onFire(false, _flags));
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = _k;
    final once = widget.state == LatchState.once, locked = widget.state == LatchState.locked;
    return Semantics(
      button: true,
      label: k.spoken,
      toggled: k.bit != null ? widget.state != LatchState.off : null,
      excludeSemantics: true,
      onTap: widget.blocked ? null : () => widget.onFire(true, null),
      child: Opacity(
        opacity: widget.blocked ? .4 : 1,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerUp: (_) => _stop(),
          onPointerCancel: (_) => _stop(),
          child: KeyFace(label: k.label, lit: once, locked: locked, onTap: widget.blocked ? null : () {}),
        ),
      ),
    );
  }
}
