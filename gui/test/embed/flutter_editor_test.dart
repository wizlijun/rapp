import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_editor.dart';
import 'package:rapp/embed/flutter_editor.dart';

import '../ui/helpers.dart';

class _Log {
  int enter = 0, escape = 0, paste = 0, changed = 0;
  final focus = <bool>[];

  /// Each onArrow's `up`; [takeArrows] is what it answers.
  final arrows = <bool>[];
  bool takeArrows = true;
  EditorHandlers get handlers => EditorHandlers(
        onChanged: () => changed++,
        onEnter: () => enter++,
        onEscape: () => escape++,
        onPaste: () => paste++,
        onFocus: focus.add,
        onArrow: (up) {
          arrows.add(up);
          return takeArrows;
        },
      );
}

const _style = EditorStyle(
  text: TextStyle(fontSize: 15, height: 22 / 15),
  color: Colors.white,
  hintColor: Colors.grey,
  cursor: Colors.green,
);

Widget _host(FlutterEditor ed, {Widget Function(Widget)? around}) {
  final v = SizedBox(
    width: 700,
    child: Builder(builder: (c) => ed.view(c, style: _style, hint: '写给 Safari', maxHeight: 200)),
  );
  return wrap(around == null ? v : around(v));
}

void main() {
  late FlutterEditor ed;
  late _Log log;

  setUp(() {
    ed = FlutterEditor();
    log = _Log();
    ed.handlers = log.handlers;
  });
  tearDown(() => ed.dispose());

  testWidgets('Enter reports, Shift+Enter is a newline, both stay with the IME while composing', (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();

    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(log.enter, 0);
    expect(log.escape, 0);

    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'a', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(await ed.read(), 'a\n');
    expect(log.enter, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(log.enter, 1);
  });

  testWidgets('Ctrl+Enter is neither a send nor a newline', (tester) async {
    var shortcut = 0;
    await tester.pumpWidget(_host(ed, around: (v) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true): () => shortcut++,
            const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true): () => shortcut++,
          },
          child: v,
        )));
    ed.focus();
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'a', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    for (final k in [LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter]) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(k);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    await tester.pump();
    expect(log.enter, 0);
    expect(await ed.read(), 'a');
    expect(shortcut, 2); // the event was not the editor's: it reached the shortcut above
  });

  testWidgets('Esc reports and never reaches a CallbackShortcuts Esc above', (tester) async {
    var outer = 0;
    await tester.pumpWidget(_host(ed,
        around: (v) => CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => outer++}, child: v)));
    ed.focus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(log.escape, 1);
    expect(outer, 0);
  });

  testWidgets('⌘V reports a paste and inserts nothing itself', (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(log.paste, 1);
    expect(await ed.read(), '');
  }, skip: !Platform.isMacOS, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a tap while composing cannot move the caret', (tester) async {
    await tester.pumpWidget(_host(ed));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    final c = field.controller!;
    final start = tester.getTopLeft(find.byType(EditableText)) + const Offset(1, 5);

    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'bu dui', selection: TextSelection.collapsed(offset: 6), composing: TextRange(start: 0, end: 6)));
    await tester.pump();

    await tester.tapAt(start);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.value.selection, const TextSelection.collapsed(offset: 6));
    expect(c.value.composing, const TextRange(start: 0, end: 6));
    expect(c.value.text, 'bu dui');

    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '不对', selection: TextSelection.collapsed(offset: 2)));
    await tester.pump();
    await tester.tapAt(start);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.value.selection, const TextSelection.collapsed(offset: 0));
  });

  testWidgets('insert while composing waits for the commit', (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2)));
    await tester.pump();
    ed.insert('X');
    await tester.pump();
    expect(await ed.read(), 'ni');
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '你', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    expect(await ed.read(), '你X');
  });

  Future<void> composeNi(WidgetTester tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2)));
    await tester.pump();
  }

  Future<void> commit(WidgetTester tester) async {
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '你', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
  }

  testWidgets('take while composing waits for the commit', (tester) async {
    await composeNi(tester);
    String? got;
    ed.take().then((s) => got = s);
    await tester.pump();
    expect(await ed.read(), 'ni');
    expect(got, isNull);
    await commit(tester);
    await tester.pump();
    expect(got, '你');
    expect(await ed.read(), '');
  });

  testWidgets('take after a pending insert takes both', (tester) async {
    await composeNi(tester);
    ed.insert('X');
    String? got;
    ed.take().then((s) => got = s);
    await commit(tester);
    await tester.pump();
    expect(got, '你X');
    expect(await ed.read(), '');
  });

  testWidgets('dispose completes a pending take', (tester) async {
    await composeNi(tester);
    String? got;
    ed.take().then((s) => got = s);
    await tester.pumpWidget(const SizedBox());
    ed.dispose();
    await tester.pump();
    expect(got, 'ni');
  });

  testWidgets('one line is 48 high; many lines stop at maxHeight and scroll', (tester) async {
    await tester.pumpWidget(_host(ed));
    expect(tester.getSize(find.byKey(const Key('composer-field'))).height, 48);
    ed.setText(List.generate(40, (i) => 'line $i').join('\n'));
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('composer-field'))).height, 200);
  });

  testWidgets('the hint shows while empty; no text glow under MATRIX', (tester) async {
    await tester.pumpWidget(_host(ed));
    expect(find.text('写给 Safari'), findsOneWidget);
    final f = tester.widget<TextField>(find.byKey(const Key('composer-field')));
    expect(f.style!.shadows, isEmpty);
  });

  testWidgets('focus and changes are reported', (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();
    expect(log.focus, [true]);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'a', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    expect(log.changed, 1);
    expect(await ed.take(), 'a');
    expect(await ed.read(), '');
  });

  testWidgets('FlutterEditor reports up only on the first line and never while composing', (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();
    TextEditingValue at(String text, int caret) =>
        TextEditingValue(text: text, selection: TextSelection.collapsed(offset: caret));
    int caret() =>
        tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.selection.baseOffset;

    // Empty: one line, both the first and the last.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(log.arrows, [true, false]);

    // Caret on the second of two lines: up moves the caret, down is reported.
    log.arrows.clear();
    log.takeArrows = false;
    tester.testTextInput.updateEditingValue(at('one\ntwo', 6));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(log.arrows, [false]);
    expect(caret(), 7); // not taken: the field moves the caret to the end itself
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(log.arrows, [false]); // not on the first line: not reported
    expect(caret(), lessThan(4)); // the caret went up a line

    // On the first line now: reported; answered false, the field moves the caret itself.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(log.arrows, [false, true]);
    expect(caret(), 0);

    // Taken: the caret stays.
    log.arrows.clear();
    log.takeArrows = true;
    tester.testTextInput.updateEditingValue(at('one\ntwo', 2));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(log.arrows, [true]);
    expect(caret(), 2);
    // Down from the first of two lines: not the last line, not reported.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(log.arrows, [true]);

    // Shift+arrow selects: never reported.
    log.arrows.clear();
    tester.testTextInput.updateEditingValue(at('one', 3));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(log.arrows, isEmpty);

    // Composing: the arrows are the input method's.
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(log.arrows, isEmpty);
  });

  testWidgets('isEmpty follows the text', (tester) async {
    await tester.pumpWidget(_host(ed));
    expect(ed.isEmpty, isTrue);
    ed.setText('a');
    expect(ed.isEmpty, isFalse);
    expect(await ed.take(), 'a');
    expect(ed.isEmpty, isTrue);
  });
}
