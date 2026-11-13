import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_menu.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/tab_chip.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/ui/app_profile_store.dart';
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
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
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

  for (final w in [360.0, 335.0, 320.0, 300.0, 240.0]) {
    testWidgets('top bar fits ${w.toInt()}px with long names', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: w,
        child: TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
      )));
      await longSession(tester);
      s.hint = 'some hint';
      await tester.pump();
      expect(tester.takeException(), isNull);
      s.toggleOverview();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('overview button only from 300px', (tester) async {
    for (final (w, shown) in [(240.0, false), (360.0, true)]) {
      await tester.pumpWidget(wrap(SizedBox(
        width: w,
        child: TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
      )));
      expect(find.byKey(const Key('overview-button')), shown ? findsOneWidget : findsNothing, reason: '$w');
    }
  });

  testWidgets('overview button toggles and shows pressed in overview', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(wrap(bar()));
    bool selected() => tester
        .widgetList<Semantics>(find.ancestor(of: find.byKey(const Key('overview-button')), matching: find.byType(Semantics)))
        .any((w) => w.properties.selected == true);
    expect(s.overview, false);
    await tester.tap(find.byKey(const Key('overview-button')));
    await tester.pump();
    expect(s.overview, true);
    expect(selected(), true);
    await tester.tap(find.byKey(const Key('overview-button')));
    await tester.pump();
    expect(s.overview, false);
    expect(selected(), false);
    h.dispose();
  });

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
      final es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
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
      s.toggleOverview();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  group('embedded width', () {
    late FakeSessionPort port;
    late MainState es;

    setUp(() {
      port = FakeSessionPort();
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          t.emit({
            'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            if (m['embed'] == true) ...{'port': 5001, 'token': 'tk'},
            'req': m['req'],
          });
        }
      };
      s.dispose();
      s = es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    });

    for (final w in [600.0, 597.0, 545.0, 480.0, 478.0, 400.0, 392.0, 340.0, 336.0, 360.0, 320.0, 300.0]) {
      testWidgets('top bar fits at $w with the stream menu', (tester) async {
        await tester.pumpWidget(wrap(Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: w,
            child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {}),
          ),
        )));
        await tester.runAsync(() async {
          es.openOrSwitch('111', 'Safari', 'Safari');
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        expect(find.byType(StreamMenuAnchor), findsOneWidget);
        expect(tester.takeException(), isNull);
        final full = tester.getRect(find.byKey(const Key('fullscreen-button')));
        final barRect = tester.getRect(find.byType(TopBar));
        expect(full.right, lessThanOrEqualTo(barRect.right + 0.01));
        expect(full.left, greaterThanOrEqualTo(barRect.left));
      });
    }
  });

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
      s = es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
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

    testWidgets('a pinned clip of an ended session offers no 插入 when its sid comes back (S6-4b)', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      await openApp(tester, 'Safari');
      port.emit(const ClipsEvent(1, [ClipRow(7, 'old', true)]));
      await tester.runAsync(() async {
        await es.togglePin(es.resources.clips.single);
        es.endCurrent();
        port.emit(const ClosedEvent(1, 'rapp-client: quit'));
        await flush();
      });
      nextSid = 0; // 重启服务: the hub numbers from 1 again
      await openApp(tester, 'Safari');
      expect(es.currentRemote!.sid, 1);
      await tester.tap(find.byKey(const Key('traffic')));
      await tester.pump();
      expect(find.text('old'), findsOneWidget);
      expect(find.text('插入'), findsNothing);
      port.emit(const ClipsEvent(1, [ClipRow(7, 'new', true)]));
      await tester.pump();
      expect(find.text('插入'), findsOneWidget);
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

  group('window tab rules', () {
    const chrome = 'com.google.Chrome';
    RemoteWindow rw(int id, String title, {WindowKind kind = WindowKind.normal, bool focused = false}) => RemoteWindow(
          id: id,
          parent: 0,
          kind: kind,
          title: title,
          rect: const Rect.fromLTWH(0, 0, 400, 328),
          titleBar: 28,
          resizable: true,
          focused: focused,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );
    const hideFloating = WindowRule(kind: WindowKind.floating, action: RuleAction.hide);

    // The status lamp animates, so pumpAndSettle would never return.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    late FakeSessionPort port;
    late MainState es;
    late AppProfileStore store;

    Future<void> setup(WidgetTester tester, List<RemoteWindow> windows, {List<WindowRule>? rules, double width = 1800}) async {
      // Wide enough that three tabs and the 已隐藏 chip all show (the tab row clips at the slack).
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      port = FakeSessionPort();
      store = AppProfileStore('${tmp.path}/shared',
          mine: [if (rules != null) AppProfile(ids: [chrome], name: 'Chrome', windows: rules)]);
      es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, profiles: store);
      addTearDown(es.dispose);
      await tester.pumpWidget(wrap(SizedBox(
        width: width,
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
        es.openOrSwitch('111', chrome, 'Chrome');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      es.stageSize(const Size(800, 600));
      port.emit(const ReadyEvent(1, 'Chrome'));
      port.emit(WindowsEvent(1, windows));
      await tester.pump();
    }

    final three = [rw(1, 'Main'), rw(2, 'Downloads', kind: WindowKind.floating), rw(3, 'Other')];

    testWidgets('right-click a tab, 隐藏这类窗口: the tab goes, a snackbar offers 撤销', (tester) async {
      await setup(tester, three);
      await tester.tap(find.text('Downloads'), buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.text('隐藏这类窗口'));
      await settle(tester);
      expect(find.text('Downloads'), findsNothing);
      expect(find.text('已隐藏 1 个'), findsOneWidget);
      expect(find.text('已隐藏，可在 app 配置里改'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await settle(tester);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('已隐藏 1 个'), findsNothing);
    });

    testWidgets('这个窗口不要输入区 shows its snackbar', (tester) async {
      await setup(tester, three);
      await tester.tap(find.text('Other'), buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.text('这个窗口不要输入区'));
      await settle(tester);
      expect(find.text('已关掉这个窗口的输入区，可在 app 配置里改'), findsOneWidget);
      expect(store.mine.single.windows!.single.action, RuleAction.noComposer);
    });

    testWidgets('隐藏这类窗口 is greyed for the main window', (tester) async {
      await setup(tester, three);
      await tester.tap(find.text('Main'), buttons: kSecondaryButton);
      await settle(tester);
      final item = tester.widget<PopupMenuItem<Object?>>(
          find.ancestor(of: find.text('隐藏这类窗口'), matching: find.byType(PopupMenuItem<Object?>)));
      expect(item.enabled, isFalse);
    });

    testWidgets('已隐藏 N 个 shows with a single tab; 这次显示 and 不再隐藏 work', (tester) async {
      final two = [rw(1, 'Main'), rw(2, 'w2', kind: WindowKind.floating)];
      await setup(tester, two, rules: [hideFloating]);
      expect(find.text('已隐藏 1 个'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hidden-tabs')));
      await settle(tester);
      expect(find.text('w2'), findsOneWidget); // the unclickable name row
      await tester.tap(find.text('这次显示'));
      await settle(tester);
      expect(find.text('w2'), findsOneWidget); // now a tab
      expect(find.text('已隐藏 1 个'), findsNothing);

      // A fresh table with the rule again: 不再隐藏 removes the rule.
      await setup(tester, two, rules: [hideFloating]);
      await tester.tap(find.byKey(const Key('hidden-tabs')));
      await settle(tester);
      await tester.tap(find.text('不再隐藏'));
      await settle(tester);
      expect(store.mine.where((p) => p.windows?.isNotEmpty ?? false), isEmpty);
      expect(find.text('已隐藏 1 个'), findsNothing);
    });

    testWidgets('已隐藏 N 个 stays on screen with many tabs at a narrow width', (tester) async {
      final many = [
        for (var i = 1; i <= 8; i++) rw(i, 'Window number $i'),
        rw(9, 'w9', kind: WindowKind.floating),
      ];
      await setup(tester, many, rules: [hideFloating], width: 800);
      final chip = find.byKey(const Key('hidden-tabs'));
      expect(chip, findsOneWidget);
      final r = tester.getRect(chip);
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(800));
      expect(tester.getRect(find.byType(TopBar)).contains(r.center), isTrue);
      // Hit-testable: tapping it opens the menu.
      await tester.tap(chip);
      await settle(tester);
      expect(find.text('这次显示'), findsOneWidget);
    });

    testWidgets('已隐藏 N 个 is selected while A focuses a hidden window', (tester) async {
      await setup(tester, [rw(1, 'Main'), rw(2, 'w2', kind: WindowKind.floating, focused: true)], rules: [hideFloating]);
      final chip = tester.widget<TabChip>(find.byKey(const Key('hidden-tabs')));
      expect(chip.selected, isTrue);
    });
  });
}
