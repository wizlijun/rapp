import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp_rime/rapp_rime.dart';

class FakeLink extends ChangeNotifier implements RimeLink {
  @override
  bool enabled = true, builtin = true, ascii = false;
  @override
  RimeStatus status = const RimeStatus(state: RimeState.ready);
  final selects = <int>[], pages = <bool>[];
  int toggles = 0;
  @override
  void attach(Object owner, void Function(RimeUpdate) onUpdate) {}
  @override
  void detach(Object owner) {}
  @override
  Future<void> setActive(Object owner, bool on) async {}
  @override
  Future<void> select(int index) async => selects.add(index);
  @override
  Future<void> page(bool next) async => pages.add(next);
  @override
  Future<bool> flush() async => true;
  @override
  Future<void> clear() async {}
  @override
  Future<void> setAscii(bool on) async {}
  @override
  void toggleBuiltin() => toggles++;
}

const menu = RimeMenu(
  rows: [RimeCandidate(0, '1', '你好'), RimeCandidate(1, '2', '拟好')],
  cursor: 0,
  next: true,
);

Widget host(FakeLink link, RimeMenu m) => MaterialApp(
  home: Scaffold(
    body: RimeCandidateRow(link: link, menu: m, style: const TextStyle(fontSize: 16)),
  ),
);

void main() {
  testWidgets('draws candidates and selects on tap', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(host(link, menu));
    expect(find.textContaining('你好', findRichText: true), findsOneWidget);
    expect(find.textContaining('拟好', findRichText: true), findsOneWidget);
    expect(find.textContaining('2 拟好', findRichText: true), findsOneWidget);
    await tester.tap(find.textContaining('拟好', findRichText: true));
    expect(link.selects, [1]);
  });

  testWidgets('arrow pages through the engine when no local page is left', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(host(link, menu));
    await tester.tap(find.text('›'));
    expect(link.pages, [true]);
  });

  testWidgets('starting shows 部署中…', (tester) async {
    final link = FakeLink()..status = const RimeStatus(state: RimeState.starting);
    await tester.pumpWidget(host(link, RimeMenu.empty));
    expect(find.text('部署中…'), findsOneWidget);
  });

  testWidgets('error shows the message', (tester) async {
    final link = FakeLink()..status = const RimeStatus(state: RimeState.error, message: 'boom');
    await tester.pumpWidget(host(link, RimeMenu.empty));
    expect(find.text('出错：boom'), findsOneWidget);
  });

  testWidgets('ascii marker and toggle', (tester) async {
    final link = FakeLink()..ascii = true;
    await tester.pumpWidget(host(link, menu));
    expect(tester.widget<Text>(find.byKey(const Key('rime-ascii'))).data, '英');
    expect(find.descendant(of: find.byKey(const Key('rime-toggle')), matching: find.text('内')), findsOneWidget);
    await tester.tap(find.byKey(const Key('rime-toggle')));
    expect(link.toggles, 1);
  });

  testWidgets('the 内/系 toggle fills the row height and is at least 44 wide', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(host(link, menu));
    final row = tester.getRect(find.byType(RimeCandidateRow));
    final toggle = tester.getRect(find.byKey(const Key('rime-toggle')));
    expect(toggle.height, row.height);
    expect(toggle.top, row.top);
    expect(toggle.width, greaterThanOrEqualTo(44));
    expect(toggle.right, row.right);
    // The bottom edge of the row (below the text line) still toggles.
    await tester.tapAt(Offset(toggle.center.dx, row.bottom - 2));
    expect(link.toggles, 1);
  });

  testWidgets('system mode shows 系 and 中', (tester) async {
    final link = FakeLink()..builtin = false;
    await tester.pumpWidget(host(link, RimeMenu.empty));
    expect(find.text('系'), findsOneWidget);
    expect(find.text('中'), findsOneWidget);
  });
}
