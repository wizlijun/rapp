import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/term/end_term_dialog.dart';

import '../ui/helpers.dart';

void main() {
  Future<Future<bool>> ask(WidgetTester t, String? fg) async {
    late BuildContext ctx;
    await t.pumpWidget(wrap(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    final answer = confirmEndTerm(ctx, fg);
    await t.pumpAndSettle();
    return answer;
  }

  testWidgets('end_dialog_when_program_running: the copy names the program; the focus is on 取消', (t) async {
    final answer = await ask(t, 'vim');
    expect(find.text('结束终端？'), findsOneWidget);
    expect(find.text('里面还在跑 vim，结束后它也会被关掉。'), findsOneWidget);
    expect(find.text('结束'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(find.ancestor(of: find.byWidget(focused.widget), matching: find.byKey(const Key('end-term-cancel'))),
        findsOneWidget);
    // Enter on the focused button is 取消.
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(await answer, isFalse);
    expect(find.text('结束终端？'), findsNothing);
  });

  testWidgets('结束 answers yes', (t) async {
    final answer = await ask(t, 'vim');
    await t.tap(find.text('结束'));
    await t.pumpAndSettle();
    expect(await answer, isTrue);
  });

  testWidgets('with no program name it says 程序', (t) async {
    final answer = await ask(t, null);
    expect(find.text('里面还在跑程序，结束后它也会被关掉。'), findsOneWidget);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(await answer, isFalse);
  });

  testWidgets('a tap outside is 取消', (t) async {
    final answer = await ask(t, 'vim');
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(await answer, isFalse);
  });
}
