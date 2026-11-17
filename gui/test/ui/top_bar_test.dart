import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_menu.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/ui/app_profile_store.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/project_menu.dart';
import 'package:rapp/ui/session_model.dart';
import 'package:rapp/ui/session_switcher.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/top_bar.dart';
import 'package:rapp/ui/window_menu.dart';
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

  testWidgets('the panel button shows the sidebar icon', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    final panel = find.byKey(const Key('panel-button'));
    expect(find.descendant(of: panel, matching: find.byIcon(Icons.view_sidebar_outlined)), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsNothing);
  });

  group('session switcher', () {
    Widget top({double width = 800}) => SizedBox(
          width: width,
          height: 600,
          child: Align(
            alignment: Alignment.topLeft,
            child: TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
          ),
        );

    Future<void> three(WidgetTester tester) async {
      await tester.runAsync(() async {
        t.emit({
          'event': 'hosts',
          'hosts': [
            {'id': '111', 'name': 'mini'},
            {'id': '222', 'name': 'studio'},
          ],
        });
        t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'Mail', 'path': 'lan'});
        t.emit({'event': 'opened', 'sid': 2, 'id': '111', 'app': 'Safari', 'path': 'lan'});
        t.emit({'event': 'opened', 'sid': 3, 'id': '222', 'app': 'Notes', 'path': 'lan'});
        await flush();
      });
      s.select('111/Mail');
      await tester.pump();
    }

    testWidgets('the session block lists open sessions by device and switches on tap', (tester) async {
      await tester.pumpWidget(wrap(top()));
      await three(tester);
      await tester.tap(find.byKey(const Key('session-block')));
      await tester.pump();
      expect(s.corner, Corner.sessions);
      expect(find.byKey(const Key('sessions-scrim')), findsOneWidget);
      expect(find.text('mini'), findsOneWidget);
      expect(find.text('studio'), findsOneWidget);
      expect(find.byKey(const ValueKey('switch-111/Mail')), findsOneWidget);
      expect(find.byKey(const ValueKey('switch-111/Safari')), findsOneWidget);
      expect(
          find.descendant(of: find.byKey(const ValueKey('switch-222/Notes')), matching: find.byType(StatusLamp)),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('switch-222/Notes')));
      await tester.pump();
      expect(s.currentKey, '222/Notes');
      expect(s.corner, isNull);
      expect(find.byKey(const Key('sessions-scrim')), findsNothing);
    });

    testWidgets('assistive tech sees the session block as one button it can press', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(top()));
      await three(tester);
      final block = find.bySemanticsLabel(RegExp('^Mail，'));
      expect(block, findsOneWidget);
      expect(tester.getSemantics(block), isSemantics(isButton: true, hasTapAction: true));
      tester.semantics.tap(find.semantics.byLabel(RegExp('^Mail，')));
      await tester.pump();
      expect(s.corner, Corner.sessions);
      handle.dispose();
    });

    testWidgets('picking the current session just closes the list', (tester) async {
      await tester.pumpWidget(wrap(top()));
      await three(tester);
      await tester.tap(find.byKey(const Key('session-block')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('switch-111/Mail')));
      await tester.pump();
      expect(s.currentKey, '111/Mail');
      expect(s.corner, isNull);
    });

    testWidgets('the list groups by device even when the panel groups by app', (tester) async {
      await tester.pumpWidget(wrap(top()));
      await three(tester);
      s.setGrouping(Grouping.app);
      await tester.tap(find.byKey(const Key('session-block')));
      await tester.pump();
      expect(find.text('mini'), findsOneWidget);
      expect(find.text('studio'), findsOneWidget);
    });

    testWidgets('no session: the block is not a button', (tester) async {
      await tester.pumpWidget(wrap(top()));
      await tester.tap(find.byKey(const Key('session-block')));
      await tester.pump();
      expect(s.corner, isNull);
      expect(find.descendant(of: find.byKey(const Key('session-block')), matching: find.byIcon(Icons.arrow_drop_down)),
          findsNothing);
    });

    testWidgets('the last session ending closes the open list', (tester) async {
      await tester.pumpWidget(wrap(top()));
      await open(tester, 1, 'Safari');
      s.select('111/Safari');
      await tester.pump();
      await tester.tap(find.byKey(const Key('session-block')));
      await tester.pump();
      expect(s.corner, Corner.sessions);
      await tester.runAsync(() async {
        t.emit({'event': 'closed', 'sid': 1});
        await flush();
      });
      await tester.pump();
      expect(s.corner, isNull);
      expect(find.byKey(const Key('sessions-scrim')), findsNothing);
    });

    testWidgets('the list fits a 320-wide window', (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(wrap(top(width: 320)));
      await three(tester);
      await tester.tap(find.byKey(const Key('session-block')));
      await tester.pump();
      final list = tester.getRect(find.byType(SessionSwitcher));
      expect(list.left, greaterThanOrEqualTo(0));
      expect(list.right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    });
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

  group('window menu', () {
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

    Future<(MainState, FakeSessionPort)> boot(WidgetTester tester, {double width = 800}) async {
      final port = FakeSessionPort();
      final es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
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
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      es.stageSize(const Size(800, 600));
      port.emit(const ReadyEvent(1, 'Safari'));
      return (es, port);
    }

    /// A menu opens and closes on its own animation; the stage keeps pumping, so never settle.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    // The session block has an arrow of its own: look for the control's inside it.
    final arrow = find.descendant(
      of: find.byKey(const Key('window-menu')),
      matching: find.byIcon(Icons.arrow_drop_down),
    );

    testWidgets('the button names the current window; the menu switches', (tester) async {
      final (es, port) = await boot(tester);
      port.emit(WindowsEvent(1, [rw(1, 'One')]));
      await tester.pump();
      // One window: its title, and nothing to open.
      expect(find.byKey(const Key('window-menu')), findsOneWidget);
      expect(find.text('One'), findsOneWidget);
      expect(arrow, findsNothing);

      port.emit(WindowsEvent(1, [rw(1, 'One'), rw(2, 'Two')]));
      await tester.pump();
      // A new window becomes current: the button names it, the other is in the menu only.
      expect(es.currentRemote!.currentWindow, 2);
      expect(find.text('Two'), findsOneWidget);
      expect(find.text('One'), findsNothing);
      expect(arrow, findsOneWidget);

      port.calls.clear();
      await tester.tap(find.byKey(const Key('window-menu')));
      await settle(tester);
      await tester.tap(find.text('One'));
      await settle(tester);
      expect(
        port.calls.any((c) => c.$1 == 'select_window' && c.$2['sid'] == 1 && c.$2['window'] == 1),
        isTrue,
      );
      final r = port.calls.where((c) => c.$1 == 'resize').toList();
      expect(r.length, 1);
      expect(r.single.$2['window'], 1);
      expect(es.currentRemote!.currentWindow, 1);
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsNothing);
    });

    testWidgets('× in the menu closes that window, never the main one', (tester) async {
      final (es, port) = await boot(tester);
      port.emit(WindowsEvent(1, [rw(1, 'One'), rw(2, 'Two')]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('window-menu')));
      await settle(tester);
      // The first window A reported is the main one: no ×.
      expect(find.byKey(const Key('close-window-1')), findsNothing);
      port.calls.clear();
      await tester.tap(find.byKey(const Key('close-window-2')));
      await settle(tester);
      expect(port.calls.any((c) => c.$1 == 'close_window' && c.$2['window'] == 2), isTrue);
    });

    testWidgets('a narrow bar leaves the count, and the title in the tooltip', (tester) async {
      final (_, port) = await boot(tester, width: 420);
      port.emit(WindowsEvent(1, [rw(1, 'A window with a long title'), rw(2, 'Two')]));
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('window-menu'))).width,
          lessThanOrEqualTo(WindowMenu.compactWidth));
      expect(tester.widget<Text>(find.byKey(const Key('window-menu-label'))).data, '2');
      expect(find.byTooltip('A window with a long title（2 个窗口）'), findsOneWidget);
      // The bar still fits: nothing overflowed.
      expect(tester.takeException(), isNull);
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
        expect(find.byKey(const Key('traffic')), findsOneWidget);
        // The 本机 and 远程 buttons come when there is room; else the traffic menu has all.
        expect(find.byType(StreamMenuAnchor), findsAtLeastNWidgets(1));
        expect(tester.takeException(), isNull);
        final full = tester.getRect(find.byKey(const Key('fullscreen-button')));
        final barRect = tester.getRect(find.byType(TopBar));
        expect(full.right, lessThanOrEqualTo(barRect.right + 0.01));
        expect(full.left, greaterThanOrEqualTo(barRect.left));
      });
    }

    testWidgets('opening the list closes 本机, and 本机 closes the list', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: 1200,
        height: 600,
        child: Align(
          alignment: Alignment.topLeft,
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
      await tester.tap(find.byKey(const Key('session-menu')));
      await tester.pump();
      expect(es.corner, Corner.session);
      await tester.tap(find.byKey(const Key('session-block')));
      await tester.pump();
      expect(es.corner, Corner.sessions);
      await tester.tap(find.byKey(const Key('session-menu')));
      await tester.pump();
      expect(es.corner, Corner.session);
    });

    testWidgets('the 本机 and 远程 buttons are icons only, even in a wide bar', (tester) async {
      await tester.pumpWidget(wrap(Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 1200, child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {})),
      )));
      await tester.runAsync(() async {
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      final local = find.byKey(const Key('session-menu'));
      final remote = find.byKey(const Key('remote-menu'));
      expect(find.descendant(of: local, matching: find.byIcon(Icons.more_horiz)), findsOneWidget);
      expect(find.descendant(of: remote, matching: find.byIcon(Icons.menu)), findsOneWidget);
      expect(find.descendant(of: local, matching: find.text('本机')), findsNothing);
      expect(find.descendant(of: remote, matching: find.text('远程')), findsNothing);
      expect(tester.getSize(local).width, 48);
      expect(tester.getSize(remote).width, 48);
      expect(find.byTooltip('本机菜单：会话、剪贴板、输入法'), findsOneWidget);
      // 远程 sits beside the window tabs, after 下一个; 本机 stays at the right, after the traffic bars.
      final next = tester.getRect(find.byKey(const Key('next')));
      final traffic = tester.getRect(find.byKey(const Key('traffic')));
      expect(tester.getRect(remote).left, greaterThanOrEqualTo(next.right));
      expect(tester.getRect(remote).right, lessThan(tester.getRect(local).left));
      expect(tester.getRect(local).left, greaterThanOrEqualTo(traffic.right - 0.01));
      // The traffic label is the bars alone: the rate is atop its menu.
      expect(tester.getSize(find.byKey(const Key('traffic'))).width, 48);
      expect(find.textContaining('KB/s'), findsNothing);
    });

    testWidgets('the row: session, remote menu | hint, right-aligned | needs, net, traffic, 本机, fullscreen', (tester) async {
      await tester.pumpWidget(wrap(Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 1200, child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {})),
      )));
      await tester.runAsync(() async {
        t.emit({'event': 'net', 'level': 'ok', 'rtt_ms': 160, 'loss': 0.03});
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      es.hint = '已打开 Safari';
      es.notifyListeners();
      await tester.pump();
      Rect r(String k) => tester.getRect(find.byKey(Key(k)));
      expect(r('prev').right, lessThanOrEqualTo(r('session-block').left + 0.01));
      expect(r('session-block').right, lessThanOrEqualTo(r('next').left + 0.01));
      expect(r('next').right, lessThanOrEqualTo(r('remote-menu').left + 0.01));
      expect(r('remote-menu').right, lessThan(r('hint-text').left));
      // Right-aligned: the line and its ▾ end where 需要你 begins.
      expect(r('hint-text').right, lessThan(r('hint-arrow').left + 0.01));
      expect(r('hint-button').right, closeTo(r('needs-you').left, 0.01));
      expect(r('needs-you').right, lessThanOrEqualTo(r('net-marker').left + 0.01));
      expect(r('net-marker').right, lessThanOrEqualTo(r('traffic').left + 0.01));
      expect(r('traffic').right, lessThanOrEqualTo(r('session-menu').left + 0.01));
      expect(r('session-menu').right, lessThanOrEqualTo(r('fullscreen-button').left + 0.01));
    });

    testWidgets('the hint keeps a history this run; its ▾ stays after the line clears and lists it', (tester) async {
      await tester.pumpWidget(wrap(Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 1200, height: 800, child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {})),
      )));
      expect(find.byKey(const Key('hint-arrow')), findsNothing); // nothing said yet
      es.hint = '已打开 Safari';
      es.hint = '';
      es.hint = '已切到 Notes';
      es.hint = '已切到 Notes'; // the line it already shows: no new record
      es.hint = '已切到 Notes；配置读不出来'; // appends to the shown line: replaces its record
      es.hint = '';
      es.notifyListeners();
      await tester.pump();
      expect(es.hintHistory.map((h) => h.text), ['已切到 Notes；配置读不出来', '已打开 Safari']);
      expect(find.byKey(const Key('hint-text')), findsNothing);
      expect(find.byKey(const Key('hint-arrow')), findsOneWidget);
      await tester.tap(find.byKey(const Key('hint-button')));
      await tester.pump();
      expect(es.corner, Corner.hints);
      final list = find.byKey(const Key('hint-history'));
      expect(find.descendant(of: list, matching: find.text('已切到 Notes；配置读不出来')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('已打开 Safari')), findsOneWidget);
      expect(
        tester.getRect(find.descendant(of: list, matching: find.text('已切到 Notes；配置读不出来'))).top,
        lessThan(tester.getRect(find.descendant(of: list, matching: find.text('已打开 Safari'))).top),
      );
      expect(find.byKey(const Key('hints-scrim')), findsOneWidget);
      await tester.tap(find.byKey(const Key('hint-button')), warnIfMissed: false);
      await tester.pump();
      expect(es.corner, isNull);
      expect(find.byKey(const Key('hint-history')), findsNothing);
    });

    test('the hint history keeps the newest 50', () {
      for (var i = 0; i < 60; i++) {
        es.hint = 'h$i';
      }
      expect(es.hintHistory, hasLength(MainState.hintHistoryMax));
      expect(es.hintHistory.first.text, 'h59');
      expect(es.hintHistory.last.text, 'h10');
    });

    testWidgets('the traffic menu starts with the rate and the link to the relay', (tester) async {
      await tester.pumpWidget(wrap(Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 1200, height: 800, child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {})),
      )));
      await tester.runAsync(() async {
        t.emit({'event': 'net', 'level': 'ok', 'rtt_ms': 160, 'loss': 0.03});
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      await tester.tap(find.byKey(const Key('traffic')));
      await tester.pump();
      expect(find.text('流量 0 KB/s'), findsOneWidget);
      expect(find.text('本机网络 · 一般 · 中继 160ms · 丢包 3%'), findsOneWidget);
      final traffic = tester.getRect(find.byKey(const Key('menu-traffic')));
      expect(tester.getRect(find.byKey(const Key('menu-net-0'))).top, greaterThanOrEqualTo(traffic.bottom));
      expect(tester.getRect(find.text('预设')).top, greaterThan(traffic.bottom));
    });

    testWidgets('no relay measured, no network marker', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {}))));
      expect(find.byKey(const Key('net-marker')), findsNothing);
    });

    for (final w in [1200.0, 1000.0, 800.0, 600.0, 545.0, 480.0, 478.0, 400.0, 360.0, 340.0, 330.0, 328.0, 327.0, 320.0, 300.0]) {
      testWidgets('top bar fits at $w with the network marker and the stream menu', (tester) async {
        await tester.pumpWidget(wrap(Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: w,
            child: TopBar(state: es, fullscreen: false, onToggleFullscreen: () {}),
          ),
        )));
        await tester.runAsync(() async {
          t.emit({'event': 'net', 'level': 'weak', 'rtt_ms': 1234, 'loss': 0.25});
          es.openOrSwitch('111', 'Safari', 'Safari');
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        // Below the bare row plus the marker (5 icons, the traffic bars and 26) there is no room.
        expect(find.byKey(const Key('net-marker')), w >= 5 * 48 + 48 + 26 ? findsOneWidget : findsNothing);
        // The line alone: the round trip is in its hover and atop the traffic menu, never in the bar.
        expect(find.textContaining('ms'), findsNothing);
        expect(tester.takeException(), isNull);
        if (w < 5 * 48 + 48 + 26) return;
        final full = tester.getRect(find.byKey(const Key('fullscreen-button')));
        final barRect = tester.getRect(find.byType(TopBar));
        expect(full.right, lessThanOrEqualTo(barRect.right + 0.01));
        final marker = tester.getRect(find.byKey(const Key('net-marker')));
        expect(marker.left, greaterThanOrEqualTo(barRect.left));
        expect(marker.right, lessThanOrEqualTo(full.left + 0.01));
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
      final local = find.byKey(const Key('session-menu'));
      await tester.tap(local.evaluate().isNotEmpty ? local : find.byKey(const Key('traffic')));
      await tester.pump();
      expect(find.text('old'), findsOneWidget);
      expect(find.text('插入'), findsNothing);
      port.emit(const ClipsEvent(1, [ClipRow(7, 'new', true)]));
      await tester.pump();
      expect(find.text('插入'), findsOneWidget);
    });

    testWidgets('the stream menu forces the current host onto the relay, only with a relay set', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      await openApp(tester, 'Safari');
      // The 会话 group sits in its own menu when the bar is split.
      Finder menu() {
        final session = find.byKey(const Key('session-menu'));
        return session.evaluate().isNotEmpty ? session : find.byKey(const Key('traffic'));
      }

      await tester.tap(menu());
      await tester.pump();
      expect(find.text('改走中继'), findsNothing);
      es.closeCorner();
      es.setRelaySet(true);
      await tester.pump();
      await tester.tap(menu());
      await tester.pump();
      await tester.ensureVisible(find.text('改走中继'));
      await tester.tap(find.text('改走中继'));
      await tester.pump();
      expect(es.corner, isNull);
      expect(t.sent.last, {'cmd': 'set_route', 'id': '111', 'route': 'relay', 'req': anything});
    });

    Finder sessionMenu() {
      final session = find.byKey(const Key('session-menu'));
      return session.evaluate().isNotEmpty ? session : find.byKey(const Key('traffic'));
    }

    testWidgets('加入项目 lists projects that do not have the session yet and adds on tap', (tester) async {
      final has = es.createProject('写周报')!;
      es.addMember(has.id, const AppRef('111', 'Safari', 'Safari'));
      final lacks = es.createProject('发版')!;
      await tester.pumpWidget(wrap(ebar()));
      await openApp(tester, 'Safari');
      await tester.tap(sessionMenu());
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('add-to-project')));
      await tester.tap(find.byKey(const Key('add-to-project')));
      await tester.pump();
      expect(find.byKey(Key('add-to-${has.id}')), findsNothing);
      expect(find.byKey(const Key('add-save-project')), findsOneWidget);
      await tester.tap(find.byKey(Key('add-to-${lacks.id}')));
      await tester.pump();
      expect(es.projects.firstWhere((p) => p.id == lacks.id).members.single.key, '111/Safari');
      expect(es.projects.firstWhere((p) => p.id == lacks.id).members.single.task, '');
      expect(es.corner, isNull);
    });

    testWidgets('加入项目 with no projects offers only 存成项目, which names the project inline', (tester) async {
      await tester.pumpWidget(wrap(ebar()));
      await openApp(tester, 'Safari');
      await tester.tap(sessionMenu());
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('add-to-project')));
      await tester.tap(find.byKey(const Key('add-to-project')));
      await tester.pump();
      expect(find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('add-to-') && w.key != const Key('add-to-project')), findsNothing);
      await tester.tap(find.byKey(const Key('add-save-project')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('save-project-name')), '写周报');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(es.projects.single.name, '写周报');
      expect(es.projects.single.members.single.key, '111/Safari');
      expect(es.currentProject, es.projects.single.id);
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

    /// The windows live in the menu now: open it before picking or right-clicking a row.
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('window-menu')));
      await settle(tester);
    }

    Future<void> closeMenu(WidgetTester tester) async {
      await tester.tapAt(const Offset(5, 400));
      await settle(tester);
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

    testWidgets('right-click a row, 隐藏这类窗口: the window goes, a snackbar offers 撤销', (tester) async {
      await setup(tester, three);
      await openMenu(tester);
      await tester.tap(find.byKey(const Key('window-row-2')), buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.text('隐藏这类窗口'));
      await settle(tester);
      expect(find.text('已隐藏，可在 app 配置里改'), findsOneWidget);
      await openMenu(tester);
      expect(find.text('Downloads'), findsOneWidget); // in the 已隐藏 group now
      expect(find.text('已隐藏 1 个'), findsOneWidget);
      await closeMenu(tester);
      await tester.tap(find.text('撤销'));
      await settle(tester);
      await openMenu(tester);
      expect(find.text('已隐藏 1 个'), findsNothing);
      expect(find.byKey(const Key('window-row-2')), findsOneWidget); // a window again
    });

    testWidgets('这个窗口不要输入区 shows its snackbar', (tester) async {
      await setup(tester, three);
      await openMenu(tester);
      await tester.tap(find.byKey(const Key('window-row-3')), buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.text('这个窗口不要输入区'));
      await settle(tester);
      expect(find.text('已关掉这个窗口的输入区，可在 app 配置里改'), findsOneWidget);
      expect(store.mine.single.windows!.single.action, RuleAction.noComposer);
    });

    testWidgets('the 隐藏这类窗口 snackbar goes away on its own', (tester) async {
      await setup(tester, three);
      await openMenu(tester);
      await tester.tap(find.byKey(const Key('window-row-2')), buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.text('隐藏这类窗口'));
      await settle(tester);
      expect(find.text('已隐藏，可在 app 配置里改'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(find.text('已隐藏，可在 app 配置里改'), findsNothing);
      await openMenu(tester);
      expect(find.text('已隐藏 1 个'), findsOneWidget);
    });

    testWidgets('隐藏这类窗口 is greyed for the main window', (tester) async {
      await setup(tester, three);
      await openMenu(tester);
      await tester.tap(find.byKey(const Key('window-row-1')), buttons: kSecondaryButton);
      await settle(tester);
      final item = tester.widget<PopupMenuItem<Object?>>(
          find.ancestor(of: find.text('隐藏这类窗口'), matching: find.byType(PopupMenuItem<Object?>)));
      expect(item.enabled, isFalse);
    });

    testWidgets('the 已隐藏 group: 这次显示 and 不再隐藏 work with one window left', (tester) async {
      final two = [rw(1, 'Main'), rw(2, 'w2', kind: WindowKind.floating)];
      await setup(tester, two, rules: [hideFloating]);
      // One window and one hidden: the menu opens for the hidden one alone.
      await openMenu(tester);
      expect(find.text('已隐藏 1 个'), findsOneWidget);
      expect(find.text('w2'), findsOneWidget); // the unclickable name row
      await tester.tap(find.text('这次显示'));
      await settle(tester);
      expect(find.text('w2'), findsOneWidget); // a window now, named on the button
      await openMenu(tester);
      expect(find.text('已隐藏 1 个'), findsNothing);
      await closeMenu(tester);

      // A fresh table with the rule again: 不再隐藏 removes the rule.
      await setup(tester, two, rules: [hideFloating]);
      await openMenu(tester);
      await tester.tap(find.text('不再隐藏'));
      await settle(tester);
      expect(store.mine.where((p) => p.windows?.isNotEmpty ?? false), isEmpty);
      await openMenu(tester);
      expect(find.text('已隐藏 1 个'), findsNothing);
    });

    testWidgets('the control stays on screen with many windows at a narrow width', (tester) async {
      final many = [
        for (var i = 1; i <= 8; i++) rw(i, 'Window number $i'),
        rw(9, 'w9', kind: WindowKind.floating),
      ];
      await setup(tester, many, rules: [hideFloating], width: 460);
      final button = find.byKey(const Key('window-menu'));
      expect(button, findsOneWidget);
      final r = tester.getRect(button);
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(460));
      expect(tester.getRect(find.byType(TopBar)).contains(r.center), isTrue);
      expect(tester.takeException(), isNull);
      // Hit-testable, and the hidden window is still reachable.
      await openMenu(tester);
      expect(find.text('这次显示'), findsOneWidget);
    });

    testWidgets('the control is selected while A focuses a hidden window', (tester) async {
      await setup(tester, [rw(1, 'Main'), rw(2, 'w2', kind: WindowKind.floating, focused: true)], rules: [hideFloating]);
      expect(tester.widget<Semantics>(find.byKey(const Key('window-menu'))).properties.selected, isTrue);
    });
  });
  group('project in the top bar', () {
    var now = DateTime(2026, 11, 15, 10);

    Future<void> boot(WidgetTester tester) async {
      s.dispose();
      now = DateTime(2026, 11, 15, 10);
      s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), clock: () => now);
      await tester.pumpWidget(wrap(bar()));
    }

    testWidgets('the cue replaces the second line for five seconds, without accent or blink', (tester) async {
      await boot(tester);
      final a = s.createProject('A')!;
      final b = s.createProject('B')!;
      s.addMember(a.id, const AppRef('111', 'Safari', 'Safari'));
      await open(tester, 1, 'Safari');
      s.switchProject(a.id);
      s.switchProject(b.id);
      now = now.add(const Duration(minutes: 25));
      s.switchProject(a.id);
      await tester.pump();
      final cue = find.byKey(const Key('return-cue'));
      final text = tester.widget<Text>(cue);
      expect(text.data, '25 分钟前离开');
      expect(text.style!.color, RappTokens.of(tester.element(cue)).muted);
      expect(text.style!.fontWeight!.value, lessThan(FontWeight.w600.value));
      expect(find.text('mini · A'), findsNothing);
      await tester.pump(MainState.cueFor);
      expect(find.byKey(const Key('return-cue')), findsNothing);
      expect(find.text('mini · A'), findsOneWidget);
    });

    testWidgets('the project menu shows with a project, ahead of the session list: 全部, projects, 自由区', (tester) async {
      await boot(tester);
      expect(find.byKey(const Key('project-menu')), findsNothing); // no project: nothing to narrow to
      final a = s.createProject('写周报')!;
      final b = s.createProject('发版')!;
      await tester.pump();
      final btn = find.byKey(const Key('project-menu'));
      expect(btn, findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('project-menu-label'))).data, '全部');
      expect(tester.widget<Icon>(find.byKey(const Key('project-menu-icon'))).icon, ProjectMenu.buttonIcon);
      expect(tester.getSize(btn).height, greaterThanOrEqualTo(48));
      // Ahead of the session list: it narrows what the list holds.
      expect(tester.getRect(btn).right, lessThanOrEqualTo(tester.getRect(find.byKey(const Key('prev'))).left + 0.01));
      expect(tester.getRect(btn).left, greaterThanOrEqualTo(tester.getRect(find.byKey(const Key('overview-button'))).right - 0.01));
      s.switchProject(a.id);
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('project-menu-label'))).data, '写周报');
      await tester.tap(btn);
      await tester.pumpAndSettle();
      final rows = ['project-row-all', 'project-row-free-zone', 'project-row-${a.id}', 'project-row-${b.id}'];
      final ys = [for (final k in rows) tester.getRect(find.byKey(Key(k))).top];
      expect([...ys]..sort(), ys, reason: '全部, 自由区, then the projects');
      expect(find.descendant(of: find.byKey(const Key('project-row-all')), matching: find.text('全部')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('project-row-free-zone')), matching: find.text('自由区')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('project-row-all')), matching: find.byIcon(ProjectMenu.allIcon)), findsOneWidget);
      expect(find.descendant(of: find.byKey(Key('project-row-${b.id}')), matching: find.byIcon(ProjectMenu.projectIcon)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('project-row-free-zone')), matching: find.byIcon(ProjectMenu.freeZoneIcon)), findsOneWidget);
      final bold = tester.widget<Text>(find.descendant(of: find.byKey(Key('project-row-${a.id}')), matching: find.text('写周报')));
      expect(bold.style!.fontWeight, FontWeight.w700, reason: 'the current one is bold');
      await tester.tap(find.byKey(Key('project-row-${b.id}')));
      await tester.pumpAndSettle();
      expect(s.currentProject, b.id);
      expect(tester.widget<Text>(find.byKey(const Key('project-menu-label'))).data, '发版');
      // The one left is marked 上一个.
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(Key('project-row-${a.id}')), matching: find.text('上一个')), findsOneWidget);
      await tester.tap(find.byKey(const Key('project-row-free-zone')));
      await tester.pumpAndSettle();
      expect((s.freeZone, s.currentProject), (true, null));
      expect(tester.widget<Text>(find.byKey(const Key('project-menu-label'))).data, '自由区');
      expect(tester.widget<Icon>(find.byKey(const Key('project-menu-icon'))).icon, ProjectMenu.buttonIcon);
      await tester.tap(btn);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-row-all')));
      await tester.pumpAndSettle();
      expect((s.freeZone, s.currentProject), (false, null));
      expect(tester.widget<Text>(find.byKey(const Key('project-menu-label'))).data, '全部');
      s.switchFreeZone();
      s.deleteProject(a.id);
      s.deleteProject(b.id);
      await tester.pump();
      expect(find.byKey(const Key('project-menu')), findsNothing, reason: 'no project: all of it is 自由区');
      expect(s.freeZone, isFalse);
      await tester.pump(MainState.undoFor);
      await tester.pump(MainState.cueFor);
    });

    testWidgets('the second line names the current project when the session is in several', (tester) async {
      await boot(tester);
      final a = s.createProject('写周报')!;
      final b = s.createProject('发版')!;
      s.addMember(a.id, const AppRef('111', 'Safari', 'Safari'));
      s.addMember(b.id, const AppRef('111', 'Safari', 'Safari'));
      await open(tester, 1, 'Safari');
      s.switchProject(b.id);
      await tester.pump();
      expect(find.text('mini · 发版等'), findsOneWidget);
    });

    testWidgets('prev/next count only the open sessions in the current project', (tester) async {
      await boot(tester);
      final a = s.createProject('A')!;
      s.addMember(a.id, const AppRef('111', 'Safari', 'Safari'));
      s.addMember(a.id, const AppRef('111', 'Notes', 'Notes')); // not open
      await open(tester, 1, 'Safari');
      await open(tester, 2, 'Mail');
      IconButton b(String k) => tester.widget<IconButton>(find.byKey(Key(k)));
      expect(b('prev').onPressed, isNotNull);
      s.switchProject(a.id);
      await tester.pump();
      expect(b('prev').onPressed, isNull);
      expect(b('next').onPressed, isNull);
      s.addMember(a.id, const AppRef('111', 'Mail', 'Mail'));
      await tester.pump();
      expect(b('prev').onPressed, isNotNull);
      expect(b('next').onPressed, isNotNull);
    });

    testWidgets('with a current project and no session the bar names the project', (tester) async {
      await boot(tester);
      final a = s.createProject('写周报')!;
      await tester.pump();
      expect(find.text('没有选中的会话'), findsOneWidget);
      s.switchProject(a.id);
      await tester.pump();
      expect(find.descendant(of: find.byKey(const Key('session-block')), matching: find.text('写周报')), findsOneWidget);
      expect(find.text('没有选中的会话'), findsNothing);
    });

    testWidgets('with nothing open in the project the cue shows under its name', (tester) async {
      await boot(tester);
      final a = s.createProject('写周报')!;
      final b = s.createProject('发版')!;
      s.switchProject(a.id);
      s.switchProject(b.id);
      now = now.add(const Duration(minutes: 25));
      s.switchProject(a.id);
      await tester.pump();
      expect(find.descendant(of: find.byKey(const Key('session-block')), matching: find.text('写周报')), findsOneWidget);
      final cue = find.byKey(const Key('return-cue'));
      expect(tester.widget<Text>(cue).data, '25 分钟前离开');
      expect(tester.widget<Text>(cue).style!.color, RappTokens.of(tester.element(cue)).muted);
      await tester.pump(MainState.cueFor);
      expect(find.byKey(const Key('return-cue')), findsNothing);
      expect(find.descendant(of: find.byKey(const Key('session-block')), matching: find.text('写周报')), findsOneWidget);
    });
  });
}
