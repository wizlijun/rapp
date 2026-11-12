import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/tab_chip.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('top_bar_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    s = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, int sid, String app) async {
    t.emit({'event': 'opened', 'sid': sid, 'id': '111', 'app': app, 'path': 'lan'});
    await tester.runAsync(flush);
    await tester.pump();
  }

  Widget bar({bool fullscreen = false}) => SizedBox(
        width: 800,
        child: TopBar(state: s, fullscreen: fullscreen, onToggleFullscreen: () {}),
      );

  testWidgets('top bar shows current session name, device and path', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    expect(find.text('没有选中的会话'), findsOneWidget);
    await tester.runAsync(() async {
      t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'Safari', 'path': 'lan'});
      await flush();
    });
    s.select('111/Safari');
    await tester.pump();
    expect(find.text('Safari'), findsOneWidget);
    expect(find.text('mini · 局域网'), findsOneWidget);
  });

  testWidgets('prev/next disabled with fewer than two sessions', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    await open(tester, 1, 'Safari');
    IconButton b(String k) => tester.widget<IconButton>(find.byKey(Key(k)));
    expect(b('prev').onPressed, isNull);
    expect(b('next').onPressed, isNull);
    expect(find.byTooltip('上一个'), findsOneWidget);
    expect(find.byTooltip('下一个'), findsOneWidget);
    expect(find.byTooltip('面板'), findsOneWidget);
    expect(find.byTooltip('进入全屏'), findsOneWidget);
  });

  testWidgets('next moves current', (tester) async {
    await tester.pumpWidget(wrap(bar(fullscreen: true)));
    await open(tester, 1, 'Mail');
    await open(tester, 2, 'Safari');
    s.select('111/Mail');
    await tester.pump();
    await tester.tap(find.byKey(const Key('next')));
    await tester.pump();
    expect(s.currentKey, '111/Safari');
    expect(find.byTooltip('退出全屏'), findsOneWidget);
  });

  testWidgets('panel button toggles the panel', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    await tester.tap(find.byKey(const Key('panel-button')));
    expect(s.panel, isNotNull);
  });

  testWidgets('long hint is one line with ellipsis', (tester) async {
    s.hint = 'x' * 500;
    await tester.pumpWidget(wrap(bar()));
    final txt = tester.widget<Text>(find.text('x' * 500));
    expect(txt.maxLines, 1);
    expect(txt.overflow, TextOverflow.ellipsis);
  });

  Future<void> longSession(WidgetTester tester) async {
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'a-very-long-device-name-that-keeps-going'},
      ],
    });
    await tester.runAsync(flush);
    final longApp = 'An Extremely Long Application Name ' * 3;
    t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': longApp, 'path': 'lan'});
    await tester.runAsync(flush);
    s.select('111/$longApp');
  }

  for (final w in [360.0, 240.0]) {
    testWidgets('top bar fits ${w.toInt()}px with long names', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: w,
        child: TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
      )));
      await longSession(tester);
      s.hint = 'some hint';
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('hint still shown at 800px with a session', (tester) async {
    s.hint = 'hello hint';
    await tester.pumpWidget(wrap(bar()));
    await open(tester, 1, 'Safari');
    s.select('111/Safari');
    await tester.pump();
    expect(find.text('hello hint'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session block announces the lamp state', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(wrap(bar()));
    await open(tester, 1, 'Safari');
    s.select('111/Safari');
    await tester.pump();
    expect(find.bySemanticsLabel('Safari，活动，mini · 局域网'), findsOneWidget);
    h.dispose();
  });

  testWidgets('unknown path falls back to the device name only', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'Safari', 'path': 'weird'});
    await tester.runAsync(flush);
    s.select('111/Safari');
    await tester.pump();
    expect(find.text('mini'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('window tabs', () {
    RemoteWindow rw(int id, String title) => RemoteWindow(
          id: id,
          parent: 0,
          kind: WindowKind.normal,
          title: title,
          rect: const Rect.fromLTWH(0, 0, 400, 328),
          titleBar: 28,
          resizable: true,
          focused: false,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    testWidgets('tabs appear at two windows and switch on tap', (tester) async {
      final port = FakeSessionPort();
      final es = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: port);
      addTearDown(es.dispose);
      await tester.pumpWidget(wrap(SizedBox(
        width: 800,
        child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {}),
      )));
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5001, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      es.stageSize(const Size(800, 600));
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(1, 'One')]));
      await tester.pump();
      expect(find.byType(TabChip), findsNothing);
      port.emit(WindowsEvent(1, [rw(1, 'One'), rw(2, 'Two')]));
      await tester.pump();
      expect(find.byType(TabChip), findsNWidgets(2));
      // A new window becomes current, so the other tab is the one to pick.
      expect(es.currentRemote!.currentWindow, 2);
      port.calls.clear();
      await tester.tap(find.widgetWithText(TabChip, 'One'));
      await tester.pump();
      expect(
        port.calls.any((c) => c.$1 == 'select_window' && c.$2['sid'] == 1 && c.$2['window'] == 1),
        isTrue,
      );
      final r = port.calls.where((c) => c.$1 == 'resize').toList();
      expect(r.length, 1);
      expect(r.single.$2['window'], 1);
      expect(es.currentRemote!.currentWindow, 1);
      expect(tester.widget<TabChip>(find.widgetWithText(TabChip, 'One')).selected, isTrue);
      expect(tester.widget<TabChip>(find.widgetWithText(TabChip, 'Two')).selected, isFalse);
    });
  });
}
