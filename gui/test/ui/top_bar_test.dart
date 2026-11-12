import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/tab_chip.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/top_bar.dart';
import 'package:rapp/ui/workspace_store.dart';

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

  testWidgets('second line shows device, project and task', (tester) async {
    final p = s.createProject('写周报')!;
    s.addMember(p.id, const AppRef('111', 'com.apple.Safari', 'Safari'));
    s.setTask(p.id, '111/com.apple.Safari', '整理 PR');
    await tester.pumpWidget(wrap(bar()));
    await open(tester, 1, 'com.apple.Safari');
    s.select('111/com.apple.Safari');
    await tester.pump();
    expect(find.text('mini · 写周报 · 整理 PR'), findsOneWidget);
    expect(find.bySemanticsLabel('com.apple.Safari，活动，mini · 写周报 · 整理 PR'), findsOneWidget);
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

  for (final w in [240.0, 360.0]) {
    testWidgets('top bar fits ${w.toInt()}px with a two-digit needs count', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: w,
        child: TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
      )));
      t.emit({
        'event': 'hosts',
        'hosts': [for (var i = 0; i < 10; i++) {'id': 'd$i', 'name': 'device $i'}],
      });
      for (var i = 0; i < 10; i++) {
        t.emit({'event': 'presence', 'id': 'd$i', 'online': true});
        t.emit({'event': 'presence', 'id': 'd$i', 'online': false});
      }
      await tester.runAsync(flush);
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('needs-count'))).data, '10');
      expect(tester.takeException(), isNull);
    });
  }

  group('needs-you', () {
    late FakeSessionPort port;
    late MainState es;
    var nextSid = 0;

    setUp(() {
      port = FakeSessionPort();
      nextSid = 0;
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          t.emit({
            'event': 'opened', 'sid': ++nextSid, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            if (m['embed'] == true) ...{'port': 5000 + nextSid, 'token': 'tk'},
            'req': m['req'],
          });
        }
      };
      // One MainState on the hub: a second would take the presence events first.
      s.dispose();
      s = es = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: port);
    });

    Widget ebar() => SizedBox(
          width: 800,
          height: 600,
          child: Align(
            alignment: Alignment.topCenter,
            child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {}),
          ),
        );

    Future<void> openApp(WidgetTester tester, String app) async {
      await tester.runAsync(() async {
        es.openOrSwitch('111', app, app);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
    }

    Future<void> dropAll(WidgetTester tester, int n) async {
      for (var sid = 1; sid <= n; sid++) {
        port.emit(DisconnectedEvent(sid, 'connection closed'));
      }
      await tester.pump();
    }

    Lamp lampOf(WidgetTester tester) => tester
        .widget<StatusLamp>(find.descendant(of: find.byKey(const Key('needs-you')), matching: find.byType(StatusLamp)))
        .kind;

    testWidgets('needs-you shows lamp and count', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      expect(find.byKey(const Key('needs-count')), findsNothing);
      expect(lampOf(tester), Lamp.active);
      expect(find.bySemanticsLabel('需要你：没有'), findsOneWidget);
      await openApp(tester, 'Safari');
      await dropAll(tester, 1);
      expect(tester.widget<Text>(find.byKey(const Key('needs-count'))).data, '1');
      expect(lampOf(tester), Lamp.disconnected);
      final size = tester.getSize(find.byKey(const Key('needs-you')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel('需要你：1 件'), findsOneWidget);
    });

    testWidgets('only a dropped device shows the offline lamp', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      t.emit({'event': 'presence', 'id': '111', 'online': true});
      t.emit({'event': 'presence', 'id': '111', 'online': false});
      await tester.runAsync(flush);
      await tester.pump();
      expect(lampOf(tester), Lamp.offline);
      expect(tester.widget<Text>(find.byKey(const Key('needs-count'))).data, '1');
    });

    testWidgets('needs popover lists three and the rest', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      await tester.tap(find.byKey(const Key('needs-you')));
      await tester.pump();
      expect(find.text('没有需要你处理的事'), findsOneWidget);
      await tester.tapAt(const Offset(10, 500));
      await tester.pump();
      expect(find.byKey(const Key('needs-scrim')), findsNothing);
      for (final app in ['a1', 'a2', 'a3', 'a4']) {
        await openApp(tester, app);
      }
      await dropAll(tester, 4);
      await tester.tap(find.byKey(const Key('needs-you')));
      await tester.pump();
      expect(find.textContaining('已断开：网络断了'), findsNWidgets(3));
      expect(find.text('还有 1 件'), findsOneWidget);
      expect(find.text('没有需要你处理的事'), findsNothing);
    });

    testWidgets('reconnect from needs keeps the selection and closes', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      await openApp(tester, 'a');
      await openApp(tester, 'b');
      es.select('111/b');
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('needs-you')));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('need-reconnect-111/a')));
        await flush();
      });
      await tester.pump();
      final open = t.sent.where((m) => m['cmd'] == 'open').last;
      expect(open['app'], 'a');
      expect(open['reconnect'], true);
      expect(es.currentKey, '111/b');
      expect(es.corner, isNull);
      expect(find.byKey(const Key('needs-scrim')), findsNothing);
    });

    testWidgets('show on a device row opens the device panel', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      t.emit({'event': 'presence', 'id': '111', 'online': true});
      t.emit({'event': 'presence', 'id': '111', 'online': false});
      await tester.runAsync(flush);
      await tester.pump();
      await tester.tap(find.byKey(const Key('needs-you')));
      await tester.pump();
      expect(find.text('mini 离线'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('need-show-111')));
        await flush();
      });
      await tester.pump();
      expect(es.panel, PanelTab.devices);
      expect(es.deviceTab, '111');
      expect(es.corner, isNull);
    });

    testWidgets('opening needs closes the stream menu', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      await openApp(tester, 'Safari');
      await tester.tap(find.byKey(const Key('traffic')));
      await tester.pump();
      expect(find.byKey(const Key('stream-menu-scrim')), findsOneWidget);
      await tester.tap(find.byKey(const Key('needs-you')));
      await tester.pump();
      expect(find.byKey(const Key('stream-menu-scrim')), findsNothing);
      expect(find.byKey(const Key('needs-scrim')), findsOneWidget);
      expect(es.corner, Corner.needs);
    });

    testWidgets('a tap outside closes the open corner, the top bar included', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      await openApp(tester, 'Safari');
      es.toggleCorner(Corner.needs);
      await tester.pump();
      expect(find.byKey(const Key('needs-scrim')), findsOneWidget);
      // The tap still reaches the button: the panel opens and the popover goes.
      await tester.tap(find.byKey(const Key('panel-button')));
      await tester.pump();
      expect(es.corner, isNull);
      expect(es.panel, isNotNull);
      expect(find.byKey(const Key('needs-scrim')), findsNothing);

      await tester.tap(find.byKey(const Key('traffic')));
      await tester.pump();
      expect(es.corner, Corner.stream);
      await tester.tap(find.byKey(const Key('fullscreen-button')));
      await tester.pump();
      expect(es.corner, isNull);
      expect(find.byKey(const Key('stream-menu-scrim')), findsNothing);

      // Below the bar too, and a tap inside the popover keeps it.
      es.toggleCorner(Corner.needs);
      await tester.pump();
      await tester.tap(find.text('没有需要你处理的事'));
      await tester.pump();
      expect(es.corner, Corner.needs);
      await tester.tapAt(const Offset(10, 500));
      await tester.pump();
      expect(es.corner, isNull);
    });
  });
}
