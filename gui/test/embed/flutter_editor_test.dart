import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_editor.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/platform_caps.dart';
import 'package:rapp_rime/rapp_rime.dart';

import '../ui/helpers.dart';
import 'fake_rime_link.dart';

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

  testWidgets('native handoff prevents the old editor from regaining input', (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.setText('retained draft');
    ed.focus();
    await tester.pump();
    ed.setHandoff(true);
    await tester.pump();
    ed.focus();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, false);
    expect(await ed.read(), 'retained draft');
    ed.setHandoff(false);
    ed.focus();
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, true);
  });

  testWidgets('handoff snapshot includes an insertion queued behind IME composition', (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2)));
    ed.insert(' pasted');
    ed.setHandoff(true);
    final snapshot = ed.read();
    await tester.pump();
    expect(await snapshot, 'ni pasted');
  });

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

  testWidgets('a labelled mark shows as a chip in the text, at its place; read gives the mark back',
      (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();
    ed.chips({0xFDD0: '[图片 #1]'});
    ed.setText('ab');
    tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: 'ab', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    ed.insert('﷐');
    await tester.pump();
    expect(await ed.read(), 'a﷐b');
    final chip = tester.getRect(find.text('[图片 #1]'));
    final field = tester.getRect(find.byKey(const Key('composer-field')));
    expect(field.contains(chip.center), isTrue);
    // A mark without a label is just text: no chip.
    ed.chips({});
    await tester.pump();
    expect(find.text('[图片 #1]'), findsNothing);
    expect(await ed.read(), 'a﷐b');
  });

  testWidgets('a chip next to composing text keeps the input method\'s underline span', (tester) async {
    await tester.pumpWidget(_host(ed));
    ed.focus();
    await tester.pump();
    ed.chips({0xFDD0: '[c]'});
    ed.setText('﷐');
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '﷐ni', selection: TextSelection.collapsed(offset: 3), composing: TextRange(start: 1, end: 3)));
    await tester.pump();
    expect(find.text('[c]'), findsOneWidget);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    final span = editable.controller.buildTextSpan(
        context: tester.element(find.byType(EditableText)), style: const TextStyle(), withComposing: true);
    final kids = span.children!;
    expect(kids.first, isA<WidgetSpan>());
    expect((kids[1] as TextSpan).text, 'ni');
    expect((kids[1] as TextSpan).style!.decoration, TextDecoration.underline);
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

  group('soft keyboard Return (iPad P1 task 9)', () {
    TextInputAction? action(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(const Key('composer-field'))).textInputAction;

    tearDown(() => lastHardwareKey = null);

    testWidgets('iOS with no hardware key: Return is a newline', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(hardwareKeyboard(), isFalse);
        await tester.pumpWidget(_host(ed));
        expect(action(tester), TextInputAction.newline);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('iOS with a hardware key in the last 10 s: the desktop rules', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        lastHardwareKey = DateTime.now();
        expect(hardwareKeyboard(), isTrue);
        await tester.pumpWidget(_host(ed));
        expect(action(tester), isNull);
        expect(hardwareKeyboard(now: DateTime.now().add(const Duration(seconds: 11))), isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('iOS: a hardware key event marks the keyboard as there', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(_host(ed));
        expect(hardwareKeyboard(), isFalse);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        expect(hardwareKeyboard(), isTrue, reason: 'a key is down');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(lastHardwareKey, isNotNull);
        expect(hardwareKeyboard(), isTrue, reason: 'pressed just now');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the desktop always has a keyboard: no newline action, Return still sends', (tester) async {
      for (final p in [TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = p;
        try {
          expect(hardwareKeyboard(), isTrue, reason: '$p');
          await tester.pumpWidget(_host(ed));
          expect(action(tester), isNull, reason: '$p');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
      ed.focus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(log.enter, 1);
    });
  });

  group('rime', () {
    late FakeRimeLink fake;

    setUp(() {
      ed.dispose();
      fake = FakeRimeLink(delayed: true);
      ed = FlutterEditor(rime: fake);
      ed.handlers = log.handlers;
    });

    void rimeTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          try {
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });

    // What the field draws: its text plus the composition.
    InlineSpan drawn(WidgetTester tester) => tester.allRenderObjects.whereType<RenderEditable>().single.text!;
    List<String> underlined(InlineSpan span) {
      final out = <String>[];
      span.visitChildren((s) {
        if (s is TextSpan && s.text != null && s.style?.decoration == TextDecoration.underline) out.add(s.text!);
        return true;
      });
      return out;
    }

    Future<void> focused(WidgetTester tester) async {
      await tester.pumpWidget(_host(ed));
      ed.focus();
      await tester.pump();
    }

    rimeTest('attaches on construction, active with focus, detaches on dispose', (tester) async {
      expect(fake.calls.first, 'attach');
      expect(fake.owner, same(ed));
      await focused(tester);
      expect(fake.calls.last, 'setActive(true)');
      final other = FlutterEditor(rime: FakeRimeLink());
      other.dispose();
      ed.dispose();
      expect(fake.calls.last, 'detach');
      expect(fake.owner, isNull);
    });

    rimeTest('rime preedit shows inline, underlined, not in the text', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni hao', input: 'nihao'));
      await tester.pump();
      expect(find.text('ni hao'), findsNothing);
      expect(find.text('写给 Safari'), findsNothing, reason: 'the hint does not cover the composition');
      expect(await ed.read(), '');
      expect(drawn(tester).toPlainText(), 'ni hao');
      expect(underlined(drawn(tester)), ['ni hao']);
    });

    rimeTest('rime preedit sits at the caret, next to a chip', (tester) async {
      await focused(tester);
      ed.chips({0xFDD0: '[c]'});
      tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: '﷐b', selection: TextSelection.collapsed(offset: 1)));
      await tester.pump();
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      await tester.pump();
      expect(find.text('[c]'), findsOneWidget);
      final kids = (drawn(tester) as TextSpan).children!;
      expect(kids.first, isA<WidgetSpan>());
      expect((kids[1] as TextSpan).text, 'ni');
      expect((kids[2] as TextSpan).text, 'b');
      expect(underlined(drawn(tester)), ['ni']);
      expect(await ed.read(), '﷐b');
    });

    rimeTest('rime commit lands at the caret', (tester) async {
      await focused(tester);
      tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: 'ab', selection: TextSelection.collapsed(offset: 1)));
      await tester.pump();
      fake.push(const RimeUpdate(commit: '你好'));
      await tester.pump();
      expect(await ed.read(), 'a你好b');
      // A commit and the next composition in one update: the composition follows the commit.
      fake.push(const RimeUpdate(commit: '我', preedit: 'ni', input: 'ni'));
      await tester.pump();
      expect(await ed.read(), 'a你好我b');
      expect(drawn(tester).toPlainText(), 'a你好我nib');
    });

    Future<void> withText(WidgetTester tester, String text, {TextSelection? selection}) async {
      tester.testTextInput.updateEditingValue(
          TextEditingValue(text: text, selection: selection ?? TextSelection.collapsed(offset: text.length)));
      await tester.pump();
    }

    rimeTest('a replayed ⌫ after a commit deletes the commit', (tester) async {
      await focused(tester);
      await withText(tester, 'abc');
      fake.push(const RimeUpdate(commit: '你'));
      fake.push(const RimeUpdate(delete: 1));
      await tester.pump();
      expect(await ed.read(), 'abc');
    });

    rimeTest('a replayed ⌫ after declined letters deletes the last one', (tester) async {
      await focused(tester);
      await withText(tester, 'x');
      fake.push(const RimeUpdate(commit: 'h'));
      fake.push(const RimeUpdate(commit: 'i'));
      fake.push(const RimeUpdate(delete: 1));
      await tester.pump();
      expect(await ed.read(), 'xh');
    });

    rimeTest('a replayed ⌫ at the start does nothing', (tester) async {
      await focused(tester);
      await withText(tester, 'ab', selection: const TextSelection.collapsed(offset: 0));
      fake.push(const RimeUpdate(delete: 1));
      await tester.pump();
      expect(await ed.read(), 'ab');
    });

    rimeTest('a replayed ⌫ with a selection deletes the selection only', (tester) async {
      await focused(tester);
      await withText(tester, 'abcd', selection: const TextSelection(baseOffset: 1, extentOffset: 3));
      fake.push(const RimeUpdate(delete: 1));
      await tester.pump();
      expect(await ed.read(), 'ad');
    });

    rimeTest('a replayed ⌫ removes a whole grapheme', (tester) async {
      await focused(tester);
      await withText(tester, 'a👍🏽');
      fake.push(const RimeUpdate(delete: 1));
      await tester.pump();
      expect(await ed.read(), 'a');
    });

    rimeTest('insert while composing commits the raw input first', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni hao', input: 'nihao'));
      ed.insert('[语音]');
      ed.insert('!');
      expect(await ed.read(), '', reason: 'the commit is still on its way');
      await tester.pump();
      expect(fake.calls.where((c) => c == 'flush'), hasLength(1), reason: 'one flush in flight at a time');
      expect(await ed.read(), 'nihao[语音]!');
      expect(drawn(tester).toPlainText(), 'nihao[语音]!');
    });

    rimeTest('setText while composing commits first, then replaces', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      ed.setText('x');
      await tester.pump();
      expect(fake.calls, contains('flush'));
      expect(await ed.read(), 'x');
    });

    rimeTest('take while composing returns the raw input', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      expect(await ed.take(), 'ni');
      await tester.pump();
      expect(await ed.read(), '');
      expect(drawn(tester).toPlainText(), '');
    });

    rimeTest('handoff read while composing includes the raw input', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      ed.setHandoff(true);
      final snapshot = ed.read();
      await tester.pump();
      expect(await snapshot, 'ni');
      expect(fake.calls.where((c) => c == 'flush'), hasLength(1), reason: 'the blur does not commit it twice');
    });

    rimeTest('blur commits the composition', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'wo', input: 'wo'));
      await tester.pump();
      ed.unfocus();
      await tester.pump();
      expect(fake.calls, containsAllInOrder(['setActive(false)', 'flush']));
      expect(await ed.read(), 'wo');
      expect(drawn(tester).toPlainText(), 'wo');
      // Nothing composing: a blur sends no flush.
      ed.focus();
      await tester.pump();
      fake.calls.clear();
      ed.unfocus();
      await tester.pump();
      expect(fake.calls, ['setActive(false)']);
    });

    rimeTest('flush failing still runs pending edits', (tester) async {
      await focused(tester);
      fake.flushOk = false;
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      ed.setText('x');
      await tester.pump();
      expect(fake.calls, contains('flush'));
      expect(await ed.read(), 'x');
      expect(drawn(tester).toPlainText(), 'x', reason: 'the composition is gone');
    });

    rimeTest('a tap while rime composes cannot move the caret', (tester) async {
      await focused(tester);
      tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: 'abc', selection: TextSelection.collapsed(offset: 3)));
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      await tester.pump();
      await tester.tapAt(tester.getTopLeft(find.byType(EditableText)) + const Offset(1, 5));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.selection,
          const TextSelection.collapsed(offset: 3));
    });

    rimeTest('switching to 系 drops the composition', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      await tester.pump();
      expect(drawn(tester).toPlainText(), 'ni');
      fake.set(builtin: false);
      await tester.pump();
      expect(drawn(tester).toPlainText(), '');
      expect(await ed.read(), '');
      expect(fake.calls, isNot(contains('flush')), reason: 'dropped, not committed');
      ed.insert('x');
      expect(await ed.read(), 'x', reason: 'nothing composing: edits apply at once');
    });

    rimeTest('turning the switch off drops the composition; on again while focused activates', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      await tester.pump();
      expect(drawn(tester).toPlainText(), 'ni');
      fake.set(enabled: false);
      await tester.pump();
      expect(drawn(tester).toPlainText(), '');
      expect(fake.calls.last, 'setActive(false)');
      fake.set(enabled: true);
      await tester.pump();
      expect(fake.calls.last, 'setActive(true)');
    });

    rimeTest('candidate row is reserved while the keyboard is there', (tester) async {
      fake.status = const RimeStatus(state: RimeState.ready, keyboard: true);
      await focused(tester);
      expect(find.byType(RimeCandidateRow), findsOneWidget);
      final state = tester.state(find.byType(EditableText));
      ed.setText(List.generate(40, (i) => 'line $i').join('\n'));
      await tester.pump();
      final row = tester.getSize(find.byType(RimeCandidateRow)).height;
      expect(row, greaterThan(0));
      expect(tester.getSize(find.byKey(const Key('composer-field'))).height + row, 200);
      fake.push(const RimeUpdate(
          preedit: 'ni',
          input: 'ni',
          menu: RimeMenu(rows: [RimeCandidate(0, '1', '你')], cursor: 0)));
      await tester.pump();
      expect(tester.widget<RimeCandidateRow>(find.byType(RimeCandidateRow)).menu.rows.single.text, '你');
      fake.set(status: const RimeStatus(state: RimeState.ready));
      await tester.pump();
      expect(find.byType(RimeCandidateRow), findsNothing);
      expect(tester.state(find.byType(EditableText)), same(state), reason: 'the field keeps its state');
      expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
    });

    rimeTest('a read while typing leaves the composition alone (the 1 s draft copy)', (tester) async {
      await focused(tester);
      tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: '你', selection: TextSelection.collapsed(offset: 1)));
      fake.push(const RimeUpdate(preedit: 'hao', input: 'hao'));
      await tester.pump();
      expect(await ed.read(), '你');
      await tester.pump();
      expect(fake.calls, isNot(contains('flush')));
      expect(drawn(tester).toPlainText(), '你hao');
    });

    rimeTest('read() once the field is gone commits the raw input first', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      await tester.pumpWidget(const SizedBox()); // the panel closes while the field has the focus
      final draft = ed.read();
      await tester.pump();
      expect(await draft, 'ni');
      expect(fake.calls.where((c) => c == 'flush'), hasLength(1));
    });

    rimeTest('dispose after the closing read keeps the letters', (tester) async {
      await focused(tester);
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      await tester.pumpWidget(const SizedBox());
      // As ComposerPanel.dispose: the draft is read, then the editor goes.
      String? draft;
      ed.read().then((t) => draft = t).whenComplete(ed.dispose);
      await tester.pump();
      expect(draft, 'ni');
      expect(fake.calls.last, 'detach');
    });

    rimeTest('two editors: B attaches while A composes, A keeps its letters', (tester) async {
      // RappRime over a channel whose native side commits on flush, pushing the update before it answers.
      const channel = MethodChannel('test/rime');
      final messenger = tester.binding.defaultBinaryMessenger;
      Future<void> native(String method, Object? args) => messenger.handlePlatformMessage(
          channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)), (_) {});
      var raw = '';
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'flush') {
          final commit = raw;
          raw = '';
          await native('update', {'commit': commit});
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final link = RappRime(channel)
        ..configure(enabled: true, builtin: true, dictionary: RimeDictionary.bundled, onBuiltin: (_) {});
      final edA = FlutterEditor(rime: link);
      await tester.pumpWidget(_host(edA));
      edA.focus();
      await tester.pump();
      raw = 'ni';
      await native('update', {'preedit': 'ni', 'input': 'ni'});
      await tester.pump();
      expect(drawn(tester).toPlainText(), 'ni');

      // A session switch: the new panel's editor attaches before the old panel goes.
      final edB = FlutterEditor(rime: link);
      addTearDown(edB.dispose);
      await tester.pumpWidget(_host(edB));
      String? draftA;
      edA.read().then((t) => draftA = t).whenComplete(edA.dispose);
      await tester.pump();
      await tester.pump();
      expect(draftA, 'ni');
      expect(await edB.read(), '');

      // After the handover, updates are B's.
      edB.focus();
      await tester.pump();
      await native('update', {'commit': '好'});
      await tester.pump();
      expect(await edB.read(), '好');
    });

    rimeTest('an update for an editor already disposed is dropped, not applied', (tester) async {
      // A handover whose flush answer is late: meanwhile the old editor goes without a closing read.
      const channel = MethodChannel('test/rime-late');
      final messenger = tester.binding.defaultBinaryMessenger;
      Future<void> native(String method, Object? args) => messenger.handlePlatformMessage(
          channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)), (_) {});
      final answer = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'flush') await answer.future;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final link = RappRime(channel)
        ..configure(enabled: true, builtin: true, dictionary: RimeDictionary.bundled, onBuiltin: (_) {});
      final edA = FlutterEditor(rime: link);
      final edB = FlutterEditor(rime: link); // handover: updates stay A's until the flush answers
      addTearDown(edB.dispose);
      edA.dispose();
      // Routed to A: must not touch its disposed controller. A throw would come back as an error reply.
      ByteData? reply;
      await messenger.handlePlatformMessage(channel.name,
          const StandardMethodCodec().encodeMethodCall(const MethodCall('update', {'commit': 'ni', 'preedit': 'hao'})),
          (r) => reply = r);
      expect(() => const StandardMethodCodec().decodeEnvelope(reply!), returnsNormally);
      answer.complete();
      await tester.pump();
      await native('update', {'commit': '好'});
      expect(await edB.read(), '好');
    });

    rimeTest('master switch off: no row, no attach side effects', (tester) async {
      fake.set(enabled: false, status: const RimeStatus(state: RimeState.ready, keyboard: true));
      fake.calls.clear();
      await focused(tester);
      expect(find.byType(RimeCandidateRow), findsNothing);
      expect(fake.calls.where((c) => c != 'setActive(false)'), isEmpty);
      fake.push(const RimeUpdate(preedit: 'ni', input: 'ni'));
      await tester.pump();
      expect(drawn(tester).toPlainText(), '', reason: 'no composition while off');
      ed.insert('x');
      expect(await ed.read(), 'x');
      expect(fake.calls, isNot(contains('flush')));
    });
  });
}
