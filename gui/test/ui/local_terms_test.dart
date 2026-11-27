// 本机列「终端」卡片 (overview-local-terms spec §3.1–§3.2).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/local_terms.dart';

import 'helpers.dart';

TermRow _row(String key, {int attached = 0, String? name}) =>
    TermRow('term:pty:$key', name ?? key, 'zsh', null, 1, attached, 1, false, false);

void main() {
  Future<void> show(WidgetTester tester, List<TermRow> rows,
      {VoidCallback? onNew, void Function(String)? onFront, double width = 220}) async {
    await tester.pumpWidget(wrap(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: LocalTerms(rows: rows, onNew: onNew, onFront: onFront)),
    )));
  }

  testWidgets('lists each terminal with its name and who is watching', (tester) async {
    await show(tester, [_row('a', name: 'zsh · ~/git/rapp'), _row('b', name: 'claude · rapp', attached: 2)], onNew: () {});
    expect(find.byKey(const Key('local-terms')), findsOneWidget);
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('zsh · ~/git/rapp'), findsOneWidget);
    expect(find.text('claude · rapp'), findsOneWidget);
    expect(find.text('2 个在看'), findsOneWidget);
    expect(find.textContaining('个在看'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty list says why to open here', (tester) async {
    await show(tester, const [], onNew: () {});
    expect(find.text('用 rapp 开的终端，其他设备也能打开'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);
  });

  testWidgets('tapping a row fronts it; tapping 新建 opens one', (tester) async {
    final fronted = <String>[];
    var news = 0;
    await show(tester, [_row('a')], onNew: () => news++, onFront: fronted.add);
    await tester.tap(find.byKey(const Key('local-term-term:pty:a')));
    await tester.tap(find.byKey(const Key('local-terms-new')));
    await tester.pump();
    expect(fronted, ['term:pty:a']);
    expect(news, 1);
  });

  testWidgets('with no onFront the rows are not buttons', (tester) async {
    await show(tester, [_row('a')], onNew: () {});
    await tester.tap(find.byKey(const Key('local-term-term:pty:a')));
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('local-term-term:pty:a')), matching: find.byType(InkWell)), findsNothing);
    expect(
        find.ancestor(of: find.byKey(const Key('local-term-term:pty:a')), matching: find.byType(InkWell)), findsNothing);
  });

  testWidgets('a long name wraps', (tester) async {
    final long = 'claude · ${'很长的项目名字' * 6}';
    await show(tester, [_row('a', name: long)], onNew: () {}, width: 120);
    expect(tester.takeException(), isNull);
    final t = tester.widget<Text>(find.text(long));
    expect(t.softWrap, isNot(false));
    expect(t.maxLines, isNull);
    expect(t.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.getSize(find.text(long)).height, greaterThan(40));
  });

  testWidgets('新建 is disabled while it waits', (tester) async {
    await show(tester, const [], onNew: null);
    expect(tester.widget<RappButton>(find.byKey(const Key('local-terms-new'))).onPressed, isNull);
  });
}
