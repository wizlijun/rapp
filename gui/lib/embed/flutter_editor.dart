// The Flutter implementation of the writing panel's editing area: a TextField that owns its
// controller and focus node and only reports to [EditorHandlers].
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/controls.dart';
import 'composer_editor.dart';
import 'linux_candidates.dart';

class FlutterEditor implements ComposerEditor, HandoffEditor {
  FlutterEditor() {
    _controller.addListener(_controllerChanged);
    _focus.addListener(_focusChanged);
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

  bool get _composing {
    final c = _controller.value.composing;
    return c.isValid && !c.isCollapsed;
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

  void _focusChanged() => handlers?.onFocus(_focus.hasFocus);

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
    final field = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) {
            final composing = value.composing.isValid && !value.composing.isCollapsed;
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
                style: (_controller.style = style).text.copyWith(color: style.color, shadows: const []),
                cursorColor: style.cursor,
                decoration: InputDecoration(
                  isCollapsed: true,
                  // 13 + 22 (one line) + 13 = 48
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: hint,
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
        child: field,
      );
    }
    return field;
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
      _pending.add(() => _setNow(text));
    } else {
      _setNow(text);
    }
  }

  @override
  void insert(String text) {
    if (_composing) {
      _pending.add(() => _insertNow(text));
    } else {
      _insertNow(text);
    }
  }

  @override
  Future<String> read() {
    if (!_handoff || !_composing) return SynchronousFuture(_controller.text);
    // Unfocus commits the local preedit. Read after that commit and any queued
    // insertions, before the native window becomes the draft's editor.
    final done = Completer<String>();
    _readers.add(done);
    _pending.add(() {
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
    _pending.add(() {
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

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = text, look = this.style;
    if (look == null || _labels.isEmpty || !t.codeUnits.any(_labels.containsKey)) {
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

    var start = 0;
    for (var i = 0; i < t.length; i++) {
      final label = _labels[t.codeUnitAt(i)];
      if (label == null) continue;
      run(start, i);
      start = i + 1;
      out.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: _Chip(label, look)));
    }
    run(start, t.length);
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
