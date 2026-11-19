// The Flutter implementation of the writing panel's editing area: a TextField that owns its
// controller and focus node and only reports to [EditorHandlers].
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rapp_rime/rapp_rime.dart';

import '../platform_caps.dart';
import '../ui/controls.dart';
import 'composer_editor.dart';
import 'linux_candidates.dart';

class FlutterEditor implements ComposerEditor, HandoffEditor {
  /// [rime] defaults to the built-in input method on iOS and to none elsewhere.
  FlutterEditor({RimeLink? rime})
      : _rime = rime ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? RappRime.instance : null) {
    _controller.addListener(_controllerChanged);
    _focus.addListener(_focusChanged);
    final r = _rime;
    if (r != null) {
      _live = r.enabled && r.builtin;
      r.attach(this, _onRime);
      r.addListener(_rimeChanged);
      _sendActive(); // attaching leaves the native side's idea of "active" stale: say it once
    }
  }

  @override
  EditorHandlers? handlers;

  final _controller = _ChipController();
  final _focus = FocusNode(debugLabel: 'composer');
  String _seen = '';
  bool _disposed = false;
  bool _handoff = false;

  /// setText / insert calls that arrived while the input method was composing.
  final _pending = <void Function()>[];

  /// The system input method's composing range, or Rime's composition (never part of the text).
  bool get _composing {
    final c = _controller.value.composing;
    return (c.isValid && !c.isCollapsed) || _controller.rimePreedit.isNotEmpty;
  }

  /// Holds [f] back until the composition is over. Rime's never ends on its own: it is committed as typed.
  void _queue(void Function() f) {
    _pending.add(f);
    if (_controller.rimePreedit.isNotEmpty) _flushRime();
  }

  // ---- Rime (iOS, hardware keyboard). With no link, or the switch off, nothing here runs or shows.

  final RimeLink? _rime;
  bool _live = false; // switch on and 「内」
  bool? _active; // what setActive last said
  bool _flushing = false;
  final _menu = ValueNotifier<RimeMenu>(RimeMenu.empty);
  final _fieldKey = GlobalKey(debugLabel: 'composer-field');

  /// Synchronous to the end. While the engine is up every text edit of a key comes through here (commits,
  /// declined printable keys, a replayed ⌫ as [RimeUpdate.delete]), in the order typed; only edits made here are
  /// sent back to the iOS text input, so nothing native edits a stale copy behind them.
  void _onRime(RimeUpdate u) {
    if (_disposed) return;
    if (u.commit.isNotEmpty) _insertNow(u.commit);
    for (var i = 0; i < u.delete; i++) {
      _backspaceNow();
    }
    final r = _rime!;
    final live = r.enabled && r.builtin;
    _menu.value = live ? u.menu : RimeMenu.empty;
    _controller.rimePreedit = live ? u.preedit : ''; // an empty one lets the pending edits run
  }

  void _rimeChanged() {
    if (_disposed) return;
    final r = _rime!;
    final live = r.enabled && r.builtin;
    // To 「系」 or switched off: the composition goes, not committed (toggleBuiltin already cleared the engine's).
    if (_live && !live) _dropRime();
    _live = live;
    _sendActive();
  }

  void _sendActive() {
    final r = _rime!;
    final on = _focus.hasFocus && r.enabled;
    if (on == _active) return;
    _active = on;
    r.setActive(this, on);
  }

  /// Commits the composition as typed; its update lands through [_onRime]. If that never comes (no plugin,
  /// no engine, a lost update), the composition is dropped here so the pending edits still run.
  void _flushRime() {
    final r = _rime;
    if (r == null || _flushing) return;
    _flushing = true;
    r.flush().catchError((Object _) => false).then((_) {
      _flushing = false;
      if (!_disposed && _controller.rimePreedit.isNotEmpty) _dropRime();
    });
  }

  void _dropRime() {
    _menu.value = RimeMenu.empty;
    _controller.rimePreedit = '';
  }

  void _controllerChanged() {
    if (_disposed) return;
    if (!_composing && _pending.isNotEmpty) {
      final todo = List.of(_pending);
      _pending.clear();
      for (final f in todo) {
        f();
      }
    }
    if (_controller.text != _seen) {
      _seen = _controller.text;
      handlers?.onChanged();
    }
  }

  void _focusChanged() {
    if (_rime != null) {
      _sendActive();
      // Tapping the picture, closing the panel, the handoff: the letters typed so far stay.
      if (!_focus.hasFocus && _controller.rimePreedit.isNotEmpty) _flushRime();
    }
    handlers?.onFocus(_focus.hasFocus);
  }

  // Enter and Esc belong to the input method while it composes (and never reach the window's
  // shortcuts, where Esc leaves fullscreen).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final hw = HardwareKeyboard.instance;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      // Ctrl+Enter is the window's (it moves the caret to the picture): neither a send nor a newline.
      if (!_composing && hw.isControlPressed && !hw.isShiftPressed && !hw.isAltPressed && !hw.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      if (_composing) return KeyEventResult.skipRemainingHandlers;
      if (hw.isShiftPressed) {
        _insertNow('\n');
      } else if (e is KeyDownEvent) {
        handlers?.onEnter();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_composing) return KeyEventResult.skipRemainingHandlers;
      handlers?.onEscape();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      // Arrows while composing are the input method's (its candidates); with a modifier they select or jump.
      if (_composing || hw.isShiftPressed || hw.isAltPressed || hw.isMetaPressed || hw.isControlPressed) {
        return KeyEventResult.ignored;
      }
      final up = k == LogicalKeyboardKey.arrowUp;
      final v = _controller.value;
      final s = v.selection;
      final at = !s.isValid ? v.text.length : (up ? s.start : s.end);
      final edge = up ? !v.text.substring(0, at).contains('\n') : !v.text.substring(at).contains('\n');
      return edge && (handlers?.onArrow(up) ?? false) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    if ((mac ? hw.isMetaPressed && !hw.isControlPressed : hw.isControlPressed && !hw.isMetaPressed) &&
        !hw.isAltPressed &&
        handlers?.onZoom != null) {
      final zoom = switch (k) {
        LogicalKeyboardKey.equal || LogicalKeyboardKey.add || LogicalKeyboardKey.numpadAdd => ZoomKey.bigger,
        LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract => ZoomKey.smaller,
        LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => ZoomKey.reset,
        _ => null,
      };
      if (zoom != null) {
        handlers!.onZoom!(zoom);
        return KeyEventResult.handled;
      }
    }
    if (mac &&
        k == LogicalKeyboardKey.keyV &&
        hw.isMetaPressed &&
        !hw.isAltPressed &&
        !hw.isControlPressed) {
      if (e is KeyDownEvent) handlers?.onPaste();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget view(BuildContext context, {required EditorStyle style, required String hint, required double maxHeight}) {
    Widget field(double maxHeight) => ConstrainedBox(
      // Keeps the field's state when the candidate row comes and goes.
      key: _rime == null ? null : _fieldKey,
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) {
            final rime = _controller.rimePreedit.isNotEmpty;
            final composing = (value.composing.isValid && !value.composing.isCollapsed) || rime;
            // A tap during composition moves the caret, and the input method then commits its
            // preedit at the old spot and starts it again at the new one: every letter lands
            // twice. While composing, taps cannot reposition the caret.
            return AbsorbPointer(
              absorbing: composing,
              child: TextField(
                key: const Key('composer-field'),
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                // Only the soft keyboard (iPad): its Return is a newline and 发送 sends (spec §8.4). With a hardware
                // keyboard the key rules above hold, as on the desktop.
                textInputAction: hardwareKeyboard() ? null : TextInputAction.newline,
                style: (_controller.style = style).text.copyWith(color: style.color, shadows: const []),
                cursorColor: style.cursor,
                // Rime's composition is drawn at the caret, which would sit before it.
                showCursor: rime ? false : null,
                decoration: InputDecoration(
                  isCollapsed: true,
                  // 13 + 22 (one line) + 13 = 48
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: rime ? null : hint,
                  hintStyle: style.text.copyWith(color: style.hintColor, shadows: const []),
                ),
              ),
            );
          },
        ),
      ),
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return LinuxCandidatesSurface(
        key: ObjectKey(this),
        focus: _focus,
        controller: _controller,
        style: style.text.copyWith(color: style.color),
        maxHeight: maxHeight,
        child: field(maxHeight),
      );
    }
    final rime = _rime;
    if (rime == null) return field(maxHeight);
    return ListenableBuilder(
      listenable: rime,
      builder: (context, _) {
        if (!rime.enabled || !rime.status.keyboard) return field(maxHeight);
        // The row stays while the keyboard is there, empty or not: the panel does not jump as candidates come.
        final rowStyle = style.text.copyWith(color: style.color, shadows: const []);
        final row = RimeCandidateRow.heightFor(context, rowStyle);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field(math.max(0.0, maxHeight - row)),
            // Part of the field for taps: on iOS a mouse, trackpad or Pencil tap outside the field unfocuses it,
            // which would commit the raw letters before the candidate's select arrives.
            TextFieldTapRegion(
              child: ValueListenableBuilder<RimeMenu>(
                valueListenable: _menu,
                builder: (context, menu, _) => RimeCandidateRow(link: rime, menu: menu, style: rowStyle),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void focus() => _focus.requestFocus();

  @override
  void chips(Map<int, String> labels) => _controller.labels = Map.of(labels);

  @override
  void unfocus() => _focus.unfocus();

  @override
  void setHandoff(bool active) {
    _handoff = active;
    _focus.canRequestFocus = !active;
    if (active) _focus.unfocus();
  }

  void _setNow(String text) {
    _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  /// One ⌫ at the caret: a selection goes as a whole, else the grapheme before the caret; nothing at the start.
  void _backspaceNow() {
    final v = _controller.value;
    final s = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    var start = s.start, end = s.end;
    if (s.isCollapsed) {
      if (end <= 0) return;
      start = end - v.text.substring(0, end).characters.last.length;
    }
    _controller.value = TextEditingValue(
      text: v.text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
    );
  }

  void _insertNow(String text) {
    final v = _controller.value;
    final s = v.selection;
    final start = s.isValid ? s.start : v.text.length;
    final end = s.isValid ? s.end : v.text.length;
    _controller.value = TextEditingValue(
      text: v.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  @override
  void setText(String text) {
    if (_composing) {
      _queue(() => _setNow(text));
    } else {
      _setNow(text);
    }
  }

  @override
  void insert(String text) {
    if (_composing) {
      _queue(() => _insertNow(text));
    } else {
      _insertNow(text);
    }
  }

  @override
  Future<String> read() {
    // Rime's composition never ends on its own. Once the field is gone (the panel closing reads the draft
    // with no blur first) or for the handoff, it is committed as typed before the read. While the field is
    // there, a read (the model's 1 s draft copy) leaves it alone: committing it would cut a word in half.
    final rime = _controller.rimePreedit.isNotEmpty && (_handoff || _fieldKey.currentContext == null);
    if (!rime && (!_handoff || !_composing)) return SynchronousFuture(_controller.text);
    // Unfocus commits the local preedit. Read after that commit and any queued
    // insertions, before the native window becomes the draft's editor.
    final done = Completer<String>();
    _readers.add(done);
    _queue(() {
      _readers.remove(done);
      done.complete(_controller.text);
    });
    return done.future;
  }

  final _readers = <Completer<String>>[];

  @override
  bool get isEmpty => _controller.text.isEmpty && _pending.isEmpty;

  @override
  Future<String> take() {
    if (!_composing) return SynchronousFuture(_takeNow());
    // Dart writes only after the commit: the take waits in line behind earlier edits.
    final done = Completer<String>();
    _takers.add(done);
    _queue(() {
      _takers.remove(done);
      done.complete(_takeNow());
    });
    return done.future;
  }

  String _takeNow() {
    final t = _controller.text;
    _controller.value = TextEditingValue.empty;
    return t;
  }

  final _takers = <Completer<String>>[];

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
    for (final c in _takers) {
      c.complete(_controller.text);
    }
    _takers.clear();
    for (final c in _readers) {
      c.complete(_controller.text);
    }
    _readers.clear();
    _controller.removeListener(_controllerChanged);
    _focus.removeListener(_focusChanged);
    _rime?.removeListener(_rimeChanged);
    _rime?.detach(this);
    _menu.dispose();
    _controller.dispose();
    _focus.dispose();
  }
}

/// Shows each labelled block mark as a chip: a [WidgetSpan] is one character, like the mark it stands
/// for, so carets, selections and Backspace keep counting right. A copy out of the field carries the
/// mark itself; pasted back here it is dropped (the composer sends a block once).
class _ChipController extends TextEditingController {
  Map<int, String> _labels = const {};
  set labels(Map<int, String> v) {
    _labels = v;
    notifyListeners(); // the same text may now draw differently
  }

  EditorStyle? style;

  /// Rime's composition: drawn at the caret, underlined, never part of [text].
  String get rimePreedit => _rimePreedit;
  String _rimePreedit = '';
  set rimePreedit(String v) {
    if (v == _rimePreedit) return;
    _rimePreedit = v;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = text, look = this.style, pre = _rimePreedit;
    final chips = look != null && _labels.isNotEmpty && t.codeUnits.any(_labels.containsKey);
    if (!chips && pre.isEmpty) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final c = value.composing;
    final composing = withComposing && value.isComposingRangeValid;
    final under = style?.merge(const TextStyle(decoration: TextDecoration.underline)) ??
        const TextStyle(decoration: TextDecoration.underline);
    final out = <InlineSpan>[];
    // Text [a, b), the input method's part underlined as the plain field does.
    void run(int a, int b) {
      if (a >= b) return;
      final cs = composing ? c.start.clamp(a, b) : b, ce = composing ? c.end.clamp(a, b) : b;
      if (cs > a) out.add(TextSpan(text: t.substring(a, cs)));
      if (ce > cs) out.add(TextSpan(text: t.substring(cs, ce), style: under));
      if (b > ce) out.add(TextSpan(text: t.substring(ce, b)));
    }

    // Rime's composition goes in once, at the caret (the end when there is none).
    final s = value.selection;
    var at = pre.isEmpty ? -1 : (s.isValid ? s.start.clamp(0, t.length) : t.length);
    void segment(int a, int b) {
      if (a <= at && at <= b) {
        final p = at;
        at = -1;
        run(a, p);
        out.add(TextSpan(text: pre, style: under));
        run(p, b);
      } else {
        run(a, b);
      }
    }

    var start = 0;
    for (var i = 0; chips && i < t.length; i++) {
      final label = _labels[t.codeUnitAt(i)];
      if (label == null) continue;
      segment(start, i);
      start = i + 1;
      out.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: _Chip(label, look)));
    }
    segment(start, t.length);
    return TextSpan(style: style, children: out);
  }
}

/// A block in the text: its label in a dashed outline, as the chips above the text used to be.
class _Chip extends StatelessWidget {
  const _Chip(this.label, this.look);
  final String label;
  final EditorStyle look;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: CustomPaint(
          foregroundPainter: DashedOutline(look.hintColor, 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: look.text.copyWith(color: look.color, shadows: const []),
              ),
            ),
          ),
        ),
      );
}
