import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/inline_edit.dart';

import 'helpers.dart';

void main() {
  testWidgets('tap edits, enter commits once', (tester) async {
    final commits = <String>[];
    await tester.pumpWidget(wrap(InlineEdit(text: 'a', onCommit: commits.add)));
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('a'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'b');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(commits, ['b']);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('losing focus commits', (tester) async {
    final commits = <String>[];
    final other = FocusNode();
    addTearDown(other.dispose);
    await tester.pumpWidget(
      wrap(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InlineEdit(text: 'a', onCommit: commits.add),
            Focus(
              focusNode: other,
              child: const SizedBox(width: 10, height: 10),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('a'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'c');
    other.requestFocus();
    await tester.pump();
    expect(commits, ['c']);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('escape cancels', (tester) async {
    final commits = <String>[];
    await tester.pumpWidget(wrap(InlineEdit(text: 'a', onCommit: commits.add)));
    await tester.tap(find.text('a'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(commits, isEmpty);
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('empty text shows the placeholder', (tester) async {
    await tester.pumpWidget(
      wrap(InlineEdit(text: '', placeholder: '添加', onCommit: (_) {})),
    );
    expect(find.text('添加'), findsOneWidget);
  });

  testWidgets('is at least 48 tall', (tester) async {
    await tester.pumpWidget(wrap(InlineEdit(text: 'a', onCommit: (_) {})));
    expect(
      tester.getSize(find.byType(InlineEdit)).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('outside text change follows when not editing', (tester) async {
    await tester.pumpWidget(wrap(InlineEdit(text: 'a', onCommit: (_) {})));
    await tester.pumpWidget(wrap(InlineEdit(text: 'b', onCommit: (_) {})));
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('the editing field is at least 48 tall', (tester) async {
    await tester.pumpWidget(wrap(InlineEdit(text: 'a', onCommit: (_) {})));
    await tester.tap(find.text('a'));
    await tester.pump();
    expect(
      tester.getSize(find.byType(TextField)).height,
      greaterThanOrEqualTo(48),
    );
  });
}
