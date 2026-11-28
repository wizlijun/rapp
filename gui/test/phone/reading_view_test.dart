import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/phone/reading_view.dart';
import 'package:rapp/term/term_model.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/tokens.dart';

TermScreen _scr(List<String> rows, {int rev = 1, int? hist, int cols = 40}) => TermScreen(
      pane: '%1',
      rev: rev,
      cols: cols,
      rows: rows.length,
      cx: 0,
      cy: 0,
      cursor: false,
      alt: false,
      full: true,
      more: false,
      lines: [for (var i = 0; i < rows.length; i++) (i, rows[i])],
      hist: hist,
      limit: hist == null ? null : 1000,
      wrapped: const {},
    );

TermModel _model(List<String> rows, {int? hist}) {
  final m = TermModel()..expect('%1');
  m.apply(_scr(rows, hist: hist));
  return m;
}

Future<void> _pump(WidgetTester tester, TermModel m) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: themeDataFor(RappTheme.matrix),
    home: Scaffold(body: PhoneReadingView(model: m)),
  ));
}

void main() {
  testWidgets('reading view anchors at the bottom', (tester) async {
    final m = _model(['⏺ 第一段。', '', '  第二段在最后。']);
    await _pump(tester, m);
    final last = tester.getRect(find.text('第二段在最后。'));
    final view = tester.getRect(find.byType(ListView));
    expect(view.bottom - last.bottom, lessThan(30));
    expect(find.text('第一段。'), findsOneWidget);
  });

  testWidgets('raw block scrolls sideways', (tester) async {
    final m = _model([
      '⏺ 表：',
      '',
      '  名称  │ ${'很长的说明' * 8}',
      '  ──────┼──────',
      '  mean  │ 平均',
    ], hist: 0);
    await _pump(tester, m);
    final raw = find.descendant(
      of: find.byType(PhoneReadingView),
      matching: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
    );
    expect(raw, findsOneWidget);
    final sc = tester.state<ScrollableState>(find.descendant(of: raw, matching: find.byType(Scrollable)));
    expect(sc.position.maxScrollExtent, greaterThan(0));
    // The page itself does not scroll sideways: the vertical list is the only other scrollable.
    final lists = tester.widgetList<Scrollable>(find.byType(Scrollable)).where((s) => s.axis == Axis.horizontal);
    expect(lists, hasLength(1));
  });

  testWidgets('only the current screen', (tester) async {
    final m = _model(['⏺ 旧的一行。', '', '  留在屏上的行。', '  最后一行。'], hist: 0);
    m.apply(_scr(['', '  留在屏上的行。', '  最后一行。', '  新来的行。'], rev: 2, hist: 1));
    expect(m.lineAt(-1), isNotNull);
    await _pump(tester, m);
    expect(find.textContaining('旧的一行'), findsNothing);
    expect(find.textContaining('新来的行'), findsOneWidget);
  });

  testWidgets('one column, no speaker sides', (tester) async {
    final m = _model(['❯ 我说的话', '', '⏺ 它回的话', '', '⏺ Ran git diff', '', '  def f(x):', '      return x']);
    await _pump(tester, m);
    final lefts = <double>{
      for (final w in tester.widgetList<Text>(find.descendant(of: find.byType(PhoneReadingView), matching: find.byType(Text))))
        tester.getTopLeft(find.byWidget(w)).dx,
    };
    expect(lefts, hasLength(1));
  });
}
