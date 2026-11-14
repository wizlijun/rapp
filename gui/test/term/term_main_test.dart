import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/disconnected_stage.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/sessions_tab.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/tab_chip.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

const app = 'term:tmux:work';

TermPane tp(int n, String command, {String title = '', bool active = false, bool dead = false, String win = '@1'}) =>
    TermPane(
      id: '%$n',
      win: win,
      window: win,
      title: title,
      command: command,
      cols: 80,
      rows: 24,
      dead: dead,
      active: active,
    );

/// The window table the port makes of [panes].
WindowsEvent windowsOf(Object sid, List<TermPane> panes) {
  final labels = tabLabels(panes);
  return WindowsEvent(sid, [
    for (final p in panes)
      RemoteWindow(
        id: p.number,
        parent: 0,
        kind: WindowKind.normal,
        title: labels[p.id]!,
        rect: Rect.zero,
        titleBar: 0,
        resizable: false,
        focused: p.active,
        texture: null,
        visible: Rect.zero,
      ),
  ]);
}

void main() {
  late FakeTransport t;
  late HubClient hub;
  late Directory tmp;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  var nextSid = 1;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('term_main_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    nextSid = 1;
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({
          'event': 'opened', 'sid': nextSid++, 'id': m['id'], 'app': m['app'], 'path': 'lan',
          'port': 5001, 'token': 'tk', 'req': m['req'],
        });
      }
    };
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
  });

  tearDown(() {
    s.dispose();
    term.dispose();
    tmp.deleteSync(recursive: true);
  });

  Widget window({double width = 1200}) => SizedBox(
        width: width,
        height: 700,
        child: Column(children: [
          TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
          Expanded(child: Stage(state: s)),
        ]),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> openTerm(WidgetTester tester, List<TermPane> panes) async {
    term.paneLists[1] = panes;
    await tester.runAsync(() async {
      s.openOrSwitch('111', app, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    term.play(const ReadyEvent(1, 'claude'));
    term.play(windowsOf(1, panes));
    // The port counts a screen as a frame: the lamp goes from connecting to live.
    term.play(const TrafficEvent(1, 0, 1));
    await settle(tester);
  }

  final two = [tp(3, 'claude', title: 'build-box', active: true), tp(4, 'logs', title: 'tail')];

  testWidgets('opening a terminal goes through the terminal port and shows TermStage', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    final open = t.sent.where((m) => m['cmd'] == 'open').single;
    expect((open['app'], open['embed']), (app, true));
    expect(term.calls.where((c) => c.$1 == 'start').single.$2['sid'], 1);
    expect(port.calls.where((c) => c.$1 == 'start'), isEmpty);
    expect(find.byType(TermStage), findsOneWidget);
    expect(find.widgetWithText(TabChip, '1.1 claude'), findsOneWidget);
    expect(find.widgetWithText(TabChip, '1.2 logs'), findsOneWidget);
    for (final c in tester.widgetList<TabChip>(find.byType(TabChip))) {
      expect((c.onClose, c.onSecondaryTap), (null, null));
    }
    // The device's current pane is the first tab, and it is viewed.
    expect(s.currentRemote!.currentWindow, 3);
    expect(term.calls.where((c) => c.$1 == 'view').last.$2['window'], 3);
  });

  testWidgets('two windows of one pane each are labelled by window number', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, [tp(3, 'claude', active: true), tp(4, 'logs', win: '@2')]);
    expect(find.widgetWithText(TabChip, '1 claude'), findsOneWidget);
    expect(find.widgetWithText(TabChip, '2 logs'), findsOneWidget);
  });

  testWidgets('app-session calls for a terminal sid never reach the native port', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    s.selectWindow(4);
    s.focusPicture(1);
    s.closeWindow(4);
    s.endCurrent();
    await settle(tester);
    expect(port.calls.where((c) => c.$2['sid'] == 1), isEmpty);
    expect(term.calls.where((c) => c.$1 == 'close').single.$2['sid'], 1);
  });

  testWidgets('the top bar and the session list carry the pane title', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    expect(find.text('claude · work'), findsOneWidget);
    expect(find.text('mini · 局域网 · build-box'), findsOneWidget);
    expect(s.current!.paneTitle, 'build-box');
    s.selectWindow(4);
    await tester.pump();
    expect(find.text('logs · work'), findsOneWidget);
    expect(find.text('mini · 局域网 · tail'), findsOneWidget);
    await tester.pumpWidget(wrap(SizedBox(width: 330, height: 400, child: SessionsTab(state: s))));
    expect(find.text('局域网 · tail'), findsOneWidget);
  });

  testWidgets('the traffic menu of a terminal has refit and no stream presets', (tester) async {
    // Narrow: the traffic label carries every part of the menu.
    await tester.pumpWidget(wrap(window(width: 600)));
    await openTerm(tester, two);
    await tester.tap(find.byKey(const Key('traffic')));
    await tester.pumpAndSettle();
    expect(find.text('按我的屏幕重排'), findsOneWidget);
    for (final gone in ['预设', '分离成独立窗口', '放左上角', '远程剪贴板', '输入区', 'app 配置…', '远程菜单']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.text('会话'), findsOneWidget);
    expect(find.text('结束会话'), findsWidgets);
    await tester.tap(find.byKey(const Key('term-refit')));
    await tester.pumpAndSettle();
    expect(term.calls.where((c) => c.$1 == 'refit').single.$2['sid'], 1);
  });

  testWidgets('a pane larger than the stage names the other clients from the device panel list', (tester) async {
    t.emit({
      'event': 'terms',
      'id': '111',
      'terms': [
        {'id': app, 'host': null, 'name': 'work', 'command': 'claude', 'panes': 2, 'attached': 3, 'activity': 0,
         'dead': false, 'unread': false},
      ],
      'hosts': [
        {'host': null},
      ],
    });
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    term.models[1]!
      ..expect('%3')
      ..apply(TermScreen(
          pane: '%3', rev: 1, cols: 300, rows: 90, cx: 0, cy: 0, cursor: true, alt: false, full: true, more: false,
          lines: [for (var i = 0; i < 90; i++) (i, 'row $i')]));
    await settle(tester);
    final note = tester.widget<Text>(find.byKey(const Key('term-scaled'))).data!;
    expect(note, startsWith('另有 2 个终端也接着这个会话。'));
    expect(note, contains('300×90'));
  });

  testWidgets('a wide bar shows no remote menu button for a terminal', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    expect(find.byKey(const Key('session-menu')), findsOneWidget);
    expect(find.byKey(const Key('remote-menu')), findsNothing);
  });

  testWidgets('the current pane closing moves to another pane and views it', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    expect(s.currentRemote!.currentWindow, 3);
    term.calls.clear();
    term.paneLists[1] = [tp(4, 'logs', active: true)];
    term.play(windowsOf(1, term.paneLists[1]!));
    await settle(tester);
    expect(s.currentRemote!.currentWindow, 4);
    expect(term.calls.where((c) => c.$1 == 'view').single.$2['window'], 4);
    expect(find.byType(TermStage), findsOneWidget);
  });

  testWidgets('a new pane does not take over the current tab', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    term.paneLists[1] = [...two, tp(5, 'htop', win: '@2')];
    term.play(windowsOf(1, term.paneLists[1]!));
    await settle(tester);
    expect(s.currentRemote!.currentWindow, 3);
    expect(find.widgetWithText(TabChip, '2 htop'), findsOneWidget);
  });

  testWidgets('a dead pane keeps its screen and says so on the tab', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    term.paneLists[1] = [tp(3, 'claude', active: true, dead: true), tp(4, 'logs')];
    term.play(windowsOf(1, term.paneLists[1]!));
    await settle(tester);
    expect(find.widgetWithText(TabChip, '1.1 claude · 已退出'), findsOneWidget);
    expect(find.byType(TermStage), findsOneWidget);
    expect(s.currentRemote!.currentWindow, 3);
  });

  testWidgets('a reconnected terminal takes the stage again and is viewed', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    term.play(const DisconnectedEvent(1, 'session ended'));
    await settle(tester);
    expect(find.byType(DisconnectedStage), findsOneWidget);
    expect(find.byType(TermStage), findsNothing);
    term.calls.clear();
    term.paneLists[2] = two;
    await tester.runAsync(() async {
      s.reconnectCurrent();
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    expect(term.calls.where((c) => c.$1 == 'start').single.$2['sid'], 2);
    term.play(windowsOf(2, two));
    await settle(tester);
    expect(find.byType(TermStage), findsOneWidget);
    expect(s.currentRecord!.lastSid, isNull);
    final v = term.calls.where((c) => c.$1 == 'view').last.$2;
    expect((v['sid'], v['window']), (2, 3));
    // The old session's link is closed on the terminal port, never the native one.
    expect(term.calls.where((c) => c.$1 == 'close').single.$2['sid'], 1);
    expect(port.calls.where((c) => c.$2['sid'] == 1 || c.$2['sid'] == 2), isEmpty);
  });

  testWidgets('without a terminal port a terminal does not open', (tester) async {
    final plain = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    addTearDown(plain.dispose);
    await tester.runAsync(() async {
      plain.openOrSwitch('111', app, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    expect(t.sent.where((m) => m['cmd'] == 'open'), isEmpty);
    expect(port.calls.where((c) => c.$1 == 'start'), isEmpty);
    expect(plain.current!.reason, '这台主控台还不能看终端会话');
    expect(plain.hint, contains('这台主控台还不能看终端会话'));
  });
}
