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
  EditorHandlers get handlers => EditorHandlers(
        onChanged: () => changed++,
        onEnter: () => enter++,
        onEscape: () => escape++,
        onPaste: () => paste++,
        onFocus: focus.add,
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
}
