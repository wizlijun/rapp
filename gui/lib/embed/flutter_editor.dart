// The Flutter implementation of the writing panel's editing area: a TextField that owns its
// controller and focus node and only reports to [EditorHandlers].
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composer_editor.dart';

class FlutterEditor implements ComposerEditor {
  FlutterEditor() {
    _controller.addListener(_controllerChanged);
    _focus.addListener(_focusChanged);
  }

  @override
  EditorHandlers? handlers;

  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'composer');
  String _seen = '';
  bool _disposed = false;

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
    if (defaultTargetPlatform == TargetPlatform.macOS &&
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
    return ConstrainedBox(
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
                style: style.text.copyWith(color: style.color, shadows: const []),
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
  }

  @override
  void focus() => _focus.requestFocus();

  @override
  void unfocus() => _focus.unfocus();

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
  Future<String> read() => SynchronousFuture(_controller.text);

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
    _controller.removeListener(_controllerChanged);
    _focus.removeListener(_focusChanged);
    _controller.dispose();
    _focus.dispose();
  }
}
