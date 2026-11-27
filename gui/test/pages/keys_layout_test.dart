import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar_keys.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/keys_page.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/key_layout.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late Directory tmp;
  late MainState s;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('keys_layout_test');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Finder k(String key) => find.byKey(Key(key));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(Builder(
      builder: (c) => TextButton(onPressed: () => openKeysPage(c, s), child: const Text('go')),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  Future<void> tapK(WidgetTester tester, String key) async {
    await tester.ensureVisible(k(key));
    await tester.tap(k(key));
    await tester.pumpAndSettle();
  }

  List<List<String>> rows() => s.quick.layout.rows;
  Set<String> ids() => {for (final a in s.quick.keys) a.id};

  testWidgets('move PgUp to row 1, drop ⌘T, add an action: the bar follows', (tester) async {
    await open(tester);
    // PgUp is row 2 cell 5; moving across rows = delete it, then row 1's ＋.
    await tapK(tester, 'layout-cell-1-5');
    await tapK(tester, 'layout-delete');
    await tapK(tester, 'layout-add-0');
    await tapK(tester, 'layout-pick-pgup');
    await tapK(tester, 'layout-cell-1-2'); // ⌘T
    expect(k('layout-delete'), findsOneWidget);
    await tapK(tester, 'layout-delete');
    await tapK(tester, 'layout-add-1');
    await tapK(tester, 'layout-pick-k:search');
    const row0 = ['tab', 'esc', 'cc', 'bksp', 'enter', 'up', 'pgup'];
    const row1 = ['copy', 'paste', 'cmd', 'ctrl', 'pgdn', 'left', 'down', 'right', 'k:search'];
    expect(rows(), [row0, row1]);
    // The real bar draws exactly this (⋯ closes row 1).
    expect(keyBarRows(layout: s.quick.layout, more: true, actionIds: ids()), [
      [...row0, 'more'],
      row1,
    ]);
    // And the editor shows it: the picked cell is there, the dropped ones are not.
    expect(k('layout-cell-1-8'), findsOneWidget);
    expect(k('layout-cell-1-9'), findsNothing);
    expect(k('layout-delete'), findsNothing); // selection cleared after a pick
  });

  testWidgets('replacing with a key already in the layout moves it, never duplicates', (tester) async {
    await open(tester);
    await tapK(tester, 'layout-cell-0-0'); // Tab
    await tapK(tester, 'layout-pick-esc'); // esc sits at 0-2
    expect(rows()[0], ['esc', 'cc', 'bksp', 'enter', 'up']);
    expect(rows()[1], KeyLayout.fallback.rows[1]);
    // Across rows: ⌃C replaced by ⌘C, which leaves row 2.
    await tapK(tester, 'layout-cell-0-1');
    await tapK(tester, 'layout-pick-copy');
    expect(rows()[0], ['esc', 'copy', 'bksp', 'enter', 'up']);
    expect(rows()[1], ['paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right']);
    // Moving forward in the same row: the later duplicate goes, the replaced cell keeps its place.
    await tapK(tester, 'layout-cell-0-0');
    await tapK(tester, 'layout-pick-up');
    expect(rows()[0], ['up', 'copy', 'bksp', 'enter']);
    final all = [...rows()[0], ...rows()[1]];
    expect(all.toSet().length, all.length);
  });

  testWidgets('add is off when the row is full', (tester) async {
    // Row 2 not empty: row 1 holds 9 at most.
    s.setKeyLayout(const KeyLayout([
      ['tab', 'stab', 'esc', 'cc', 'bksp', 'enter', 'up', 'left', 'right'],
      ['copy'],
    ]));
    await open(tester);
    await tapK(tester, 'layout-add-0');
    expect(tester.widget<Text>(k('layout-hint')).data, '先点一格或行末的＋'); // the ＋ did not turn on
    await tapK(tester, 'layout-pick-down');
    expect(rows()[0], hasLength(9));
    expect(rows()[0], isNot(contains('down')));
    // Row 2 can still take one (its own cap is 10).
    await tapK(tester, 'layout-add-1');
    await tapK(tester, 'layout-pick-down');
    expect(rows()[1], ['copy', 'down']);

    // Row 1 at 10, row 2 empty: row 1 is full and row 2's ＋ is off (⋯ would be the 11th).
    s.setKeyLayout(const KeyLayout([
      ['tab', 'stab', 'esc', 'cc', 'bksp', 'enter', 'up', 'left', 'right', 'down'],
      [],
    ]));
    await tester.pumpAndSettle();
    await tapK(tester, 'layout-add-0');
    expect(tester.widget<Text>(k('layout-hint')).data, '先点一格或行末的＋'); // the ＋ did not turn on
    await tapK(tester, 'layout-pick-copy');
    await tapK(tester, 'layout-add-1');
    expect(tester.widget<Text>(k('layout-hint')).data, '先点一格或行末的＋'); // the ＋ did not turn on
    await tapK(tester, 'layout-pick-copy');
    expect(rows()[0], hasLength(10));
    expect(rows()[1], isEmpty);
    expect(k('layout-add-1-note'), findsOneWidget);
    // One fewer in row 1 and row 2's ＋ works, then row 1 is capped at 9.
    await tapK(tester, 'layout-cell-0-9');
    await tapK(tester, 'layout-delete');
    expect(k('layout-add-1-note'), findsNothing);
    await tapK(tester, 'layout-add-1');
    await tapK(tester, 'layout-pick-copy');
    expect(rows()[1], ['copy']);
    expect(rows()[0], hasLength(9));
  });

  testWidgets('restore layout gives the default', (tester) async {
    s.setKeyLayout(const KeyLayout([
      ['esc'],
      ['up'],
    ]));
    await open(tester);
    expect(s.quick.layout.isDefault, isFalse);
    await tapK(tester, 'keys-restore-layout');
    expect(rows(), KeyLayout.fallback.rows);
    expect(s.quick.layout.isDefault, isTrue);
    expect(find.text('恢复默认布局'), findsOneWidget);
  });

  testWidgets('restoring the default layout clears the selection', (tester) async {
    s.setKeyLayout(const KeyLayout([
      ['up', 'esc', 'tab'],
      ['copy'],
    ]));
    await open(tester);
    await tapK(tester, 'layout-cell-0-0'); // ↑
    expect(k('layout-delete'), findsOneWidget);
    await tapK(tester, 'keys-restore-layout');
    expect(rows(), KeyLayout.fallback.rows);
    // Cell 0-0 is Tab now: a lit cell (and 删除这一格) would point at a key the user never picked.
    expect(k('layout-delete'), findsNothing);
    expect(tester.widget<Text>(k('layout-hint')).data, '先点一格或行末的＋');
    // A ＋ that was on goes off too.
    await tapK(tester, 'layout-add-0');
    expect(tester.widget<Text>(k('layout-hint')).data, '点下面的键加到第 1 行末尾');
    await tapK(tester, 'keys-restore-layout');
    expect(tester.widget<Text>(k('layout-hint')).data, '先点一格或行末的＋');
  });

  testWidgets('a layout changed elsewhere clears the selection', (tester) async {
    await open(tester);
    await tapK(tester, 'layout-cell-0-0'); // Tab
    expect(k('layout-delete'), findsOneWidget);
    // Another device's layout comes in: same lengths, other keys.
    s.setKeyLayout(KeyLayout([
      ['up', ...KeyLayout.fallback.rows[0].where((id) => id != 'up')],
      KeyLayout.fallback.rows[1],
    ]));
    await tester.pumpAndSettle();
    expect(k('layout-delete'), findsNothing);
    expect(tester.widget<Text>(k('layout-hint')).data, '先点一格或行末的＋');
    await tapK(tester, 'layout-add-0');
    s.setKeyLayout(KeyLayout.fallback);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(k('layout-hint')).data, '先点一格或行末的＋');
  });

  testWidgets('a pick with nothing selected does nothing; ⋯ is shown but not selectable', (tester) async {
    await open(tester);
    await tapK(tester, 'layout-pick-cr');
    expect(rows(), KeyLayout.fallback.rows);
    expect(k('layout-cell-0-7'), findsNothing); // row 1 has 7 cells: ⋯ is not cell 7
    expect(k('layout-more'), findsOneWidget);
    await tapK(tester, 'layout-more');
    expect(k('layout-delete'), findsNothing);
    expect(k('layout-pick-more'), findsNothing);
  });

  testWidgets('deleting every cell shows the default again', (tester) async {
    s.setKeyLayout(const KeyLayout([
      ['esc'],
      [],
    ]));
    await open(tester);
    await tapK(tester, 'layout-cell-0-0');
    await tapK(tester, 'layout-delete');
    expect(s.quick.layout.isDefault, isTrue);
    expect(k('layout-cell-1-9'), findsOneWidget);
  });

  testWidgets('drag swaps within a row only', (tester) async {
    await open(tester);
    await tester.ensureVisible(k('layout-cell-0-0'));
    final from = tester.getCenter(k('layout-cell-0-0'));
    final to = tester.getCenter(k('layout-cell-0-3'));
    await tester.timedDragFrom(from, to - from, const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(rows()[0], ['esc', 'cc', 'bksp', 'tab', 'enter', 'up']);
    expect(rows()[1], KeyLayout.fallback.rows[1]);
    // Dragged towards the other row: nothing crosses (the drag stays horizontal, and a drop is taken only in its own row).
    final f2 = tester.getCenter(k('layout-cell-0-0'));
    final t2 = tester.getCenter(k('layout-cell-1-3'));
    await tester.timedDragFrom(f2, t2 - f2, const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(rows()[1], KeyLayout.fallback.rows[1]);
    expect(rows()[0].toSet(), {'tab', 'esc', 'cc', 'bksp', 'enter', 'up'});
  });
}
