import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/keys_page.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/key_actions.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/side_panel.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late Directory tmp;
  late MainState s;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('keys_page_test');
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
    tester.view.physicalSize = const Size(800, 2400);
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

  testWidgets('add ⌃⌥X and it is saved', (tester) async {
    await open(tester);
    await tapK(tester, 'keys-add');
    await tester.enterText(k('keyact-name'), '我的键');
    await tapK(tester, 'keyact-mod-ctrl');
    await tapK(tester, 'keyact-mod-alt');
    await tapK(tester, 'keyact-key-x');
    await tapK(tester, 'keyact-save');
    final a = s.quick.keys.last;
    expect(a.label, '我的键');
    expect(a.chord, const Chord('x', ctrl: true, alt: true));
    expect(s.quick.keys, hasLength(builtinKeyActions.length + 1));
    expect(k('keys-row-${a.id}'), findsOneWidget);
  });

  testWidgets('save is off without a name or a key', (tester) async {
    await open(tester);
    await tapK(tester, 'keys-add');
    // Nothing yet: tapping save leaves the editor open.
    await tapK(tester, 'keyact-save');
    expect(k('keyact-name'), findsOneWidget);
    await tester.enterText(k('keyact-name'), '甲');
    await tester.pump();
    await tapK(tester, 'keyact-save'); // name but no key
    expect(k('keyact-name'), findsOneWidget);
    await tester.enterText(k('keyact-name'), '   ');
    await tapK(tester, 'keyact-key-x'); // key but a blank name
    await tapK(tester, 'keyact-save');
    expect(k('keyact-name'), findsOneWidget);
    expect(s.quick.keys, hasLength(builtinKeyActions.length));
  });

  testWidgets('edit keeps the id; swipe deletes; drag reorders', (tester) async {
    await open(tester);
    await tester.tap(k('keys-row-mode'));
    await tester.pumpAndSettle();
    await tester.enterText(k('keyact-name'), '换模式');
    await tapK(tester, 'keyact-save');
    final m = s.quick.keys.firstWhere((a) => a.id == 'mode');
    expect(m.label, '换模式');
    expect(m.chord, const Chord('tab', shift: true));
    expect(s.quick.keys.map((a) => a.id).toList(), builtinKeyActions.map((a) => a.id).toList());

    s.toggleStar('k:clear');
    expect(s.quick.stars, contains('k:clear'));
    await tester.drag(k('keys-row-clear'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(s.quick.keys.any((a) => a.id == 'clear'), isFalse);
    expect(s.quick.stars, isNot(contains('k:clear')));

    // search, mode, expand, bg, newtab are left; drag search down past two rows.
    expect(s.quick.keys.map((a) => a.id).toList(), ['search', 'mode', 'expand', 'bg', 'newtab']);
    final rowH = tester.getRect(k('keys-row-search')).height;
    final handle = find.descendant(of: k('keys-row-search'), matching: find.byIcon(Icons.drag_handle));
    final g = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await g.moveBy(Offset(0, rowH * 1.7));
    await tester.pump();
    await g.moveBy(Offset(0, rowH * 1.7));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(s.quick.keys.map((a) => a.id).toList(), ['mode', 'expand', 'search', 'bg', 'newtab']);
  });

  testWidgets('edit keeps per (and the id) on the page', (tester) async {
    final per = {'agy': null, 'codex': const Chord('r', alt: true)};
    s.setKeyActions([
      KeyAction('search', label: '搜历史', chord: const Chord('r', ctrl: true), per: per),
      ...builtinKeyActions.skip(1),
    ]);
    await open(tester);
    await tester.tap(k('keys-row-search'));
    await tester.pumpAndSettle();
    await tester.enterText(k('keyact-name'), '找历史');
    await tapK(tester, 'keyact-save');
    final a = s.quick.keys.first;
    expect(a.id, 'search');
    expect(a.label, '找历史');
    expect(a.per, per);
  });

  testWidgets('restore brings back the six built-ins', (tester) async {
    s.setKeyActions([const KeyAction('only', label: '独', chord: Chord('q'))]);
    await open(tester);
    expect(k('keys-row-only'), findsOneWidget);
    await tapK(tester, 'keys-restore-actions');
    expect(s.quick.keys, builtinKeyActions);
  });

  testWidgets('side panel 按键 row opens the page', (tester) async {
    s.togglePanel();
    await tester.pumpWidget(wrap(SidePanel(state: s, devicesTab: const Text('d'))));
    await tester.pump();
    await tester.ensureVisible(k('keys-settings'));
    expect(find.descendant(of: k('keys-settings'), matching: find.text('${s.quick.keys.length} 个')), findsOneWidget);
    await tester.tap(k('keys-settings'));
    await tester.pumpAndSettle();
    expect(k('keys-add'), findsOneWidget);
  });
}
