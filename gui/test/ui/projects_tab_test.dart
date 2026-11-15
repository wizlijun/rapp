import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/projects_tab.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/workspace_store.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;
  var withDevices = true;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> boot() async {
    tmp = Directory.systemTemp.createTempSync('projects_tab_test');
    t = FakeTransport();
    hub = HubClient(t);
    final hosts = withDevices
        ? [
            {'id': '111', 'name': 'mini'},
            {'id': '222', 'name': 'air'},
          ]
        : <Map<String, dynamic>>[];
    t.onSend = (cmd) {
      final req = cmd['req'];
      switch (cmd['cmd']) {
        case 'hosts':
          t.emit({'event': 'hosts', 'req': req, 'hosts': hosts});
        case 'apps':
          if (cmd['id'] == '111') {
            t.emit({
              'event': 'apps',
              'req': req,
              'id': '111',
              'path': 'lan',
              'apps': [
                {'app': 'com.apple.Safari', 'name': 'Safari'},
                {'app': 'com.apple.Notes', 'name': 'Notes'},
              ],
            });
          } else {
            t.emit({
              'event': 'error',
              'req': req,
              'error': 'connect timed out',
            });
          }
        case 'open':
          t.emit({
            'event': 'opened',
            'req': req,
            'sid': 1,
            'id': cmd['id'],
            'app': cmd['app'],
            'path': 'lan',
          });
      }
    };
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
    await flush();
    await flush();
    await flush();
  }

  setUp(() => withDevices = true);

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    s.togglePanel(PanelTab.projects);
    await tester.runAsync(() async {
      s.probeAll();
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pumpWidget(
      wrap(SizedBox(width: 720, height: 800, child: ProjectsTab(state: s))),
    );
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  const safari = AppRef('111', 'com.apple.Safari', 'Safari');
  const notes = AppRef('111', 'com.apple.Notes', 'Notes');

  Future<String> oneProject(
    WidgetTester tester, {
    List<AppRef> members = const [],
  }) async {
    final p = s.createProject('写周报')!;
    for (final m in members) {
      s.addMember(p.id, m);
    }
    await tester.pump();
    return p.id;
  }

  testWidgets('enter on 新建项目 creates a card and clears the field', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    await tester.enterText(find.byKey(const Key('new-project')), '写周报');
    await done(tester);
    expect(s.projects.single.name, '写周报');
    expect(find.byKey(Key('project-${s.projects.single.id}')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('new-project')))
          .controller!
          .text,
      '',
    );
  });

  testWidgets('no projects: only the two buttons, no guidance', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    expect(find.text('新建项目'), findsOneWidget);
    expect(find.text('存成项目'), findsOneWidget);
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .toSet();
    expect(texts, {'新建项目', '存成项目'});
  });

  bool enabled(WidgetTester tester, Key k) => tester
      .widget<OutlinedButton>(
        find.descendant(of: find.byKey(k), matching: find.byType(OutlinedButton)),
      )
      .onPressed !=
      null;

  testWidgets('存成项目 is disabled with nothing open and creates a project when something is', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    expect(enabled(tester, const Key('save-open')), isFalse);
    await tester.runAsync(() async {
      await s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
      await flush();
    });
    await tester.pump();
    expect(enabled(tester, const Key('save-open')), isTrue);
    await tester.tap(find.byKey(const Key('save-open')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('new-project')), '开着的');
    await done(tester);
    expect(s.projects.single.name, '开着的');
    expect(s.projects.single.members.single.key, '111/com.apple.Safari');
    expect(s.currentProject, s.projects.single.id);
  });

  testWidgets('新建项目 leaves save mode: Enter then creates an empty project', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    await tester.runAsync(() async {
      await s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
      await flush();
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-open')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('new-project')), '空的');
    await tester.tap(find.byKey(const Key('new-mode')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('new-project')), '空的');
    await done(tester);
    expect(s.projects.single.name, '空的');
    expect(s.projects.single.members, isEmpty);
  });

  testWidgets('save mode ends when nothing is open any more: Enter creates a plain project', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    await tester.runAsync(() async {
      await s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
      await flush();
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-open')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('new-project')), '甲');
    await tester.runAsync(() async {
      t.emit({'event': 'closed', 'sid': 1});
      await flush();
    });
    await tester.pump();
    expect(s.canSaveOpenAsProject, isFalse);
    expect(find.byKey(const Key('new-mode')), findsNothing);
    await done(tester);
    expect(s.projects.single.name, '甲');
  });

  testWidgets('pinned projects come first; the pin button toggles its label', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    final a = s.createProject('甲')!;
    final b = s.createProject('乙')!;
    await tester.pump();
    expect(find.descendant(of: find.byKey(Key('pin-${b.id}')), matching: find.text('固定')), findsOneWidget);
    await tester.tap(find.byKey(Key('pin-${b.id}')));
    await tester.pump();
    expect(s.projects.firstWhere((p) => p.id == b.id).pinned, isTrue);
    expect(find.descendant(of: find.byKey(Key('pin-${b.id}')), matching: find.text('取消固定')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(Key('project-${b.id}'))).dy,
      lessThan(tester.getTopLeft(find.byKey(Key('project-${a.id}'))).dy),
    );
  });

  testWidgets('切到 switches and marks the card as current', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final a = s.createProject('甲')!;
    final b = s.createProject('乙')!;
    await tester.pump();
    BoxDecoration deco(String id) => tester
        .widget<Container>(find.descendant(
          of: find.byKey(Key('project-$id')),
          matching: find.byType(Container),
        ).first)
        .decoration! as BoxDecoration;
    final before = deco(b.id).border;
    await tester.tap(find.byKey(Key('switch-${b.id}')));
    await tester.pump();
    expect(s.currentProject, b.id);
    expect(deco(b.id).border, isNot(before));
    expect(deco(a.id).border, before);
  });

  testWidgets('delete is one tap, shows 撤销, and 撤销 brings the card back', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester);
    expect(find.byKey(const Key('undo-delete')), findsNothing);
    await tester.tap(find.byKey(Key('delete-project-$id')));
    await tester.pump();
    expect(s.projects, isEmpty);
    expect(find.byKey(Key('project-$id')), findsNothing);
    expect(find.text('已删除「写周报」'), findsOneWidget);
    await tester.tap(find.byKey(const Key('undo-delete')));
    await tester.pump();
    expect(find.byKey(Key('project-$id')), findsOneWidget);
    expect(find.byKey(const Key('undo-delete')), findsNothing);
    await tester.pump(MainState.undoFor);
  });

  testWidgets('the undo row disappears after five seconds', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester);
    await tester.tap(find.byKey(Key('delete-project-$id')));
    await tester.pump();
    expect(find.byKey(const Key('undo-delete')), findsOneWidget);
    await tester.pump(MainState.undoFor);
    await tester.pump();
    expect(find.byKey(const Key('undo-delete')), findsNothing);
    expect(find.textContaining('已删除'), findsNothing);
  });

  testWidgets('the member note placeholder says 备注', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    await oneProject(tester, members: [safari]);
    expect(find.text('备注'), findsOneWidget);
    expect(find.textContaining('Agent'), findsNothing);
  });

  testWidgets('every new control is at least 48 high', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester);
    expect(tester.getSize(find.byKey(const Key('save-open'))).height, greaterThanOrEqualTo(48));
    for (final k in ['switch-$id', 'pin-$id']) {
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48));
    }
    await tester.tap(find.byKey(Key('delete-project-$id')));
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('undo-delete'))).height, greaterThanOrEqualTo(48));
    await tester.pump(MainState.undoFor);
  });

  testWidgets('切到 and 固定 sit in the title row; a long name on a narrow card does not overflow', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester, members: [safari, notes]);
    double mid(String k) => tester.getCenter(find.byKey(Key(k))).dy;
    expect(mid('switch-$id'), moreOrLessEquals(mid('project-name-$id'), epsilon: 1));
    expect(mid('pin-$id'), moreOrLessEquals(mid('project-name-$id'), epsilon: 1));
    expect(mid('switch-$id'), lessThan(tester.getRect(find.byKey(Key('open-all-$id'))).top));
    s.renameProject(id, '一个很长很长很长很长很长很长很长很长很长很长的项目名字');
    await tester.pumpWidget(wrap(SizedBox(width: 300, height: 800, child: ProjectsTab(state: s))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(Key('switch-$id'))).height, greaterThanOrEqualTo(48));
    expect(tester.getRect(find.byKey(Key('pin-$id'))).right, lessThanOrEqualTo(tester.getRect(find.byType(ProjectsTab)).right));
  });

  testWidgets('tap the name to rename', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester);
    await tester.tap(find.byKey(Key('project-name-$id')));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, '周报');
    await done(tester);
    expect(s.projects.single.name, '周报');
  });

  testWidgets('add app lists online apps and favorites and stays open', (
    tester,
  ) async {
    await tester.runAsync(boot);
    s.toggleFavorite('222', 'com.apple.Chess', 'Chess');
    await pump(tester);
    final id = await oneProject(tester);
    await tester.tap(find.byKey(Key('add-member-$id')));
    await tester.pump();
    expect(find.byKey(Key('add-$id-111/com.apple.Safari')), findsOneWidget);
    expect(find.byKey(Key('add-$id-111/com.apple.Notes')), findsOneWidget);
    expect(find.byKey(Key('add-$id-222/com.apple.Chess')), findsOneWidget);
    await tester.tap(find.byKey(Key('add-$id-111/com.apple.Safari')));
    await tester.pump();
    expect(find.byKey(Key('member-$id-111/com.apple.Safari')), findsOneWidget);
    expect(find.byKey(Key('add-$id-111/com.apple.Safari')), findsNothing);
    expect(find.byKey(Key('add-$id-111/com.apple.Notes')), findsOneWidget);
    await tester.tap(find.byKey(Key('add-member-$id')));
    await tester.pump();
    expect(find.byKey(Key('add-$id-111/com.apple.Notes')), findsNothing);
  });

  testWidgets('empty add list explains', (tester) async {
    withDevices = false;
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester);
    await tester.tap(find.byKey(Key('add-member-$id')));
    await tester.pump();
    expect(find.text('没有可加的 app：先在「设备」里连上一台设备，或设一个常用'), findsOneWidget);
  });

  testWidgets('member row shows app @ device, task placeholder and status', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester, members: [safari]);
    expect(find.text('Safari @ mini'), findsOneWidget);
    expect(find.text('备注'), findsOneWidget);
    expect(find.text('未打开'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(Key('member-open-$id-111/com.apple.Safari')),
        matching: find.text('打开'),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(Key('member-$id-111/com.apple.Safari'))).height,
      68,
    );
    expect(
      tester.getSize(find.byKey(Key('open-all-$id'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester
          .widget<ButtonStyleButton>(
            find.descendant(
              of: find.byKey(Key('open-all-$id')),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('editing a task saves it', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester, members: [safari]);
    await tester.tap(find.byKey(Key('task-$id-111/com.apple.Safari')));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, '整理 PR');
    await done(tester);
    expect(s.projects.single.members.single.task, '整理 PR');
    expect(find.text('整理 PR'), findsOneWidget);
  });

  testWidgets('移出 removes the member', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester, members: [safari, notes]);
    await tester.tap(find.byKey(Key('member-remove-$id-111/com.apple.Safari')));
    await tester.pump();
    expect(s.projects.single.members.map((m) => m.key), [
      '111/com.apple.Notes',
    ]);
    expect(find.byKey(Key('member-$id-111/com.apple.Safari')), findsNothing);
  });

  testWidgets('title lamps show one lamp per member', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester, members: [safari, notes]);
    expect(
      find.descendant(
        of: find.byKey(Key('project-lamps-$id')),
        matching: find.byType(StatusLamp),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('member open button follows the session', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester, members: [safari]);
    t.emit({
      'event': 'opened',
      'sid': 1,
      'id': '111',
      'app': 'com.apple.Safari',
      'path': 'lan',
    });
    await tester.runAsync(flush);
    await tester.pump();
    final open = find.byKey(Key('member-open-$id-111/com.apple.Safari'));
    expect(
      find.descendant(of: open, matching: find.text('切到')),
      findsOneWidget,
    );
    await tester.tap(open);
    await tester.pump();
    expect(s.panel, isNull);
    expect(t.sent.last['cmd'], 'focus');
  });

  ButtonStyleButton openAll(WidgetTester tester, String id) =>
      tester.widget<ButtonStyleButton>(
        find.descendant(
          of: find.byKey(Key('open-all-$id')),
          matching: find.byType(FilledButton),
        ),
      );

  ButtonStyleButton endAll(WidgetTester tester, String id) =>
      tester.widget<ButtonStyleButton>(
        find.descendant(
          of: find.byKey(Key('end-all-$id')),
          matching: find.byType(TextButton),
        ),
      );

  testWidgets('全部打开 is primary and disabled without members', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester);
    final button = openAll(tester, id);
    expect(button.onPressed, isNull);
    // Primary: filled with the text colour (controls.dart RappButton.primary).
    final tokens = RappTokens.of(tester.element(find.byKey(Key('open-all-$id'))));
    expect(button.style!.backgroundColor!.resolve({}), tokens.text);
    expect(tester.widget<RappButton>(find.byKey(Key('open-all-$id'))).label, '全部打开');
    s.addMember(id, safari);
    await tester.pump();
    expect(openAll(tester, id).onPressed, isNotNull);
  });

  testWidgets('全部结束 needs two taps and is disabled with no sessions', (
    tester,
  ) async {
    await tester.runAsync(boot);
    await pump(tester);
    final id = await oneProject(tester, members: [safari]);
    expect(endAll(tester, id).onPressed, isNull);
    t.emit({
      'event': 'opened',
      'sid': 1,
      'id': '111',
      'app': 'com.apple.Safari',
      'path': 'lan',
    });
    await tester.runAsync(flush);
    await tester.pump();
    expect(endAll(tester, id).onPressed, isNotNull);
    await tester.tap(find.byKey(Key('end-all-$id')));
    await tester.pump();
    expect(find.text('再点一次确认'), findsOneWidget);
    expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
    await tester.tap(find.text('再点一次确认'));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'close').map((m) => m['sid']), [1]);
    expect(s.hint, '写周报：结束 1 个会话');
  });

  testWidgets('全部打开 closes the panel', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    expect(s.panel, PanelTab.projects);
    final id = await oneProject(tester, members: [safari]);
    await tester.tap(find.byKey(Key('open-all-$id')));
    await tester.pump();
    expect(s.panel, isNull);
    expect(s.currentKey, '111/com.apple.Safari');
    expect(t.sent.where((m) => m['cmd'] == 'open'), hasLength(1));
    await tester.runAsync(flush);
  });

  testWidgets('the new-project field is at least 48 tall', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    expect(
      tester.getSize(find.byKey(const Key('new-project'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('focusProject scrolls the card into view and clears', (tester) async {
    await tester.runAsync(boot);
    await pump(tester);
    final ids = [for (var i = 0; i < 12; i++) s.createProject('项目$i')!.id];
    await tester.pump();
    final last = Key('project-${ids.last}');
    expect(tester.getTopLeft(find.byKey(last)).dy, greaterThan(800));
    s.showProject(ids.last);
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.byKey(last)).dy;
    expect(top, inInclusiveRange(0, 800));
    expect(s.focusProject, isNull);
  });
}
