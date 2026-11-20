import 'dart:async';
import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:rapp/pages/ios_local_section.dart';
import 'package:rapp/pages/rime_settings_section.dart';
import 'package:rapp/embed/rime_glue.dart';
import 'package:rapp_rime/rapp_rime.dart';
import 'package:rapp/pages/local_section.dart';
import 'package:rapp/platform_caps.dart';
import 'package:rapp/ui/access_setup.dart';
import 'package:rapp/ui/shares_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/picture.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/fullscreen.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/log_screen.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/side_panel.dart';
import 'package:rapp/ui/top_bar.dart';

import 'package:rapp/ui/unlock.dart';
import '../fakes.dart';
import 'desktop_test.dart' show DesktopEnv;
import 'helpers.dart';

class FakeFullscreen implements FullscreenControl {
  bool on = false;
  final calls = <bool>[];
  final _changes = StreamController<bool>.broadcast();
  @override
  Stream<bool> get changes => _changes.stream;
  @override
  Future<bool> isFullScreen() async => on;
  @override
  Future<void> setFullScreen(bool v) async {
    calls.add(v);
    on = v;
  }

  /// The OS changed fullscreen on its own (green button etc.).
  void osSet(bool v) {
    on = v;
    _changes.add(v);
  }
}

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;
  late FakeFullscreen fs;
  late ServiceMonitor monitor;
  String? openError;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    openError = null;
    tmp = Directory.systemTemp.createTempSync('main_window_test');
    t = FakeTransport();
    hub = HubClient(t);
    fs = FakeFullscreen();
    monitor = ServiceMonitor(readToken: () async => null);
    t.onSend = (cmd) {
      final req = cmd['req'];
      switch (cmd['cmd']) {
        case 'hosts':
          t.emit({
            'event': 'hosts',
            'req': req,
            'hosts': [
              {'id': '111', 'name': 'mini'},
            ],
          });
        case 'apps':
          t.emit({
            'event': 'apps',
            'req': req,
            'id': cmd['id'],
            'path': 'lan',
            'apps': [
              {'app': 'com.apple.Safari', 'name': 'Safari'},
            ],
          });
        case 'open':
          if (openError != null) {
            return t.emit({'event': 'error', 'req': req, 'error': openError});
          }
          t.emit({'event': 'opened', 'req': req, 'sid': 1, 'id': cmd['id'], 'app': cmd['app'], 'path': 'lan'});
      }
    };
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, {double w = 1194, double h = 834}) async {
    tester.view.physicalSize = Size(w, h);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      for (var i = 0; i < 3; i++) {
        await flush();
      }
    });
    await tester.pumpWidget(wrap(
      MainWindow(state: s, monitor: monitor, control: null, fullscreen: fs),
      disableAnimations: true,
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 3; i++) {
        await flush();
      }
    });
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('two asks open one unlock dialog and the password is sent', (tester) async {
    final e = DesktopEnv();
    addTearDown(e.dispose);
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => e.state.openOrSwitch('111', 'app', 'App'));
    await tester.pumpWidget(wrap(
      MainWindow(state: e.state, monitor: monitor, control: null, fullscreen: fs),
      disableAnimations: true,
    ));
    final sid = e.sid('app');
    e.port.emit(ScreenLockedEvent(sid, true));
    await tester.runAsync(() => flush());
    await tester.pump();
    e.port.emit(ScreenLockedEvent(sid, false));
    e.port.emit(ScreenLockedEvent(sid, true));
    await tester.runAsync(() => flush());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(UnlockDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'typed secret');
    await tester.tap(find.widgetWithText(FilledButton, '输入系统密码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(e.calls('unlock').single['password'], 'typed secret');
    await tester.pump(const Duration(seconds: 6)); // the 5 s check settles
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a covered notice shows its buttons; 关掉它 asks A, × closes', (tester) async {
    final e = DesktopEnv();
    addTearDown(e.dispose);
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => e.state.openOrSwitch('111', 'app', 'App'));
    await tester.pumpWidget(wrap(
      MainWindow(state: e.state, monitor: monitor, control: null, fullscreen: fs),
      disableAnimations: true,
    ));
    final sid = e.sid('app');
    e.port.emit(CoveredEvent(sid, 3, '通知中心', 'com.apple.notificationcenterui', true));
    await tester.runAsync(() => flush());
    await tester.pump();
    expect(find.text('A 上「通知中心」的弹窗挡住了点击'), findsOneWidget);
    expect(find.text('在桌面会话里处理'), findsOneWidget);
    await tester.tap(find.text('关掉它'));
    await tester.pump();
    expect(e.calls('dismiss_cover').single, {'sid': sid, 'id': 3});
    expect(find.byKey(const Key('host-notice')), findsNothing);
    e.port.emit(CoveredEvent(sid, 4, '安全代理', 'com.apple.SecurityAgent', false));
    await tester.runAsync(() => flush());
    await tester.pump();
    expect(find.text('关掉它'), findsNothing);
    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pump();
    expect(find.byKey(const Key('host-notice')), findsNothing);
    await tester.pump(const Duration(seconds: 1)); // the stage's resize settles
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the service status tells MainState whether a relay is set', (tester) async {
    monitor.status = ServiceStatus.fromJson({'relay_addr': 'vps:22026', 'has_key': true});
    await pump(tester);
    expect(s.relaySet, isTrue);
  });

  group('iOS: the hub in process, no service', () {
    late PlatformCaps was;
    var hasKey = false;

    setUp(() {
      was = caps;
      caps = PlatformCaps.forOs('ios');
      hasKey = false;
      final base = t.onSend!;
      t.onSend = (cmd) {
        switch (cmd['cmd']) {
          case 'access':
            t.emit({'event': 'access', 'relay': hasKey ? 'r:1' : null, 'has_key': hasKey, 'name': 'iPad', 'req': cmd['req']});
          case 'set_access':
            hasKey = true;
            t.emit({'event': 'access', 'relay': cmd['relay'], 'has_key': true, 'name': 'iPad', 'req': cmd['req']});
          default:
            base(cmd);
        }
      };
      s.overview = true;
    });
    tearDown(() => caps = was);

    Future<void> pumpIos(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(
        MainWindow(state: s, monitor: null, control: null, fullscreen: fs),
        disableAnimations: true,
      ));
      await settle(tester);
    }

    testWidgets('no key: AccessSetup stands where the overview was, until 接入 works', (tester) async {
      await pumpIos(tester);
      expect(find.byType(AccessSetup), findsOneWidget);
      expect(find.byType(Overview), findsNothing);
      expect(s.relaySet, isFalse);
      await tester.enterText(find.byKey(const Key('access-relay')), 'r:1');
      await tester.enterText(find.byKey(const Key('access-key')), 'k');
      await tester.pump();
      await tester.tap(find.byKey(const Key('access-go')));
      await settle(tester);
      expect(find.byType(AccessSetup), findsNothing);
      expect(find.byType(Overview), findsOneWidget);
      expect(s.relaySet, isTrue);
    });

    testWidgets('a key: the overview, relaySet from has_key, and the slim 本机 without ports', (tester) async {
      hasKey = true;
      await pumpIos(tester);
      expect(find.byType(AccessSetup), findsNothing);
      expect(find.byType(Overview), findsOneWidget);
      expect(s.relaySet, isTrue);
      s.togglePanel(PanelTab.devices);
      await settle(tester);
      expect(find.byType(IosLocalSection), findsOneWidget);
      expect(find.byType(LocalSection), findsNothing);
      expect(find.byType(SharesSection), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('全局设置 has the built-in input method\'s block while its switch is on, and nothing (no gap) when off',
        (tester) async {
      hasKey = true;
      final rime = RappRime(const MethodChannel('rapp/rime-main-window-test'));
      final glue = RimeGlue(s, rime: rime);
      addTearDown(() {
        glue.dispose();
        rime.dispose();
      });
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      s.togglePanel(PanelTab.devices);
      await tester.pumpWidget(wrap(
        MainWindow(state: s, monitor: null, control: null, fullscreen: fs, rime: glue),
        disableAnimations: true,
      ));
      await settle(tester);
      expect(find.byType(RimeSettingsSection), findsOneWidget);
      s.setRimeEnabled(false);
      await settle(tester);
      expect(find.byType(RimeSettingsSection), findsNothing);
      expect(tester.widget<SidePanel>(find.byType(SidePanel)).settings, isNull);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a fullscreen button, and no 端口 on a device page', (tester) async {
      hasKey = true;
      await pumpIos(tester);
      expect(find.byKey(const Key('fullscreen-button')), findsOneWidget);
      expect(find.byType(TopBar), findsOneWidget);
      s.showDevice('111');
      await settle(tester);
      expect(s.deviceTab, '111');
      expect(find.byType(SharesSection), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('iPad: the local page has 更多 too', (tester) async {
      hasKey = true;
      s.overview = false;
      s.togglePanel(PanelTab.devices);
      await pumpIos(tester);
      expect(find.byKey(const Key('access-log-more')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no fullscreen control: no fullscreen button', (tester) async {
      hasKey = true;
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(
        MainWindow(state: s, monitor: null, control: null, fullscreen: const NoFullscreen()),
        disableAnimations: true,
      ));
      await settle(tester);
      expect(find.byKey(const Key('fullscreen-button')), findsNothing);
      expect(find.byType(TopBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    // Home bar 20, the camera on the left (20) in landscape, a rounded corner on the right (30).
    MediaQueryData insets(MediaQueryData m, {bool keyboard = false}) => m.copyWith(
          padding: EdgeInsets.only(left: 20, right: 30, bottom: keyboard ? 0 : 20),
          viewPadding: const EdgeInsets.only(left: 20, right: 30, bottom: 20),
          viewInsets: EdgeInsets.only(bottom: keyboard ? 300 : 0),
        );

    Future<void> pumpIosInsets(WidgetTester tester, {bool keyboard = false}) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(
        Builder(
          builder: (context) => MediaQuery(
            data: insets(MediaQuery.of(context), keyboard: keyboard),
            child: MainWindow(state: s, monitor: null, control: null, fullscreen: fs),
          ),
        ),
        disableAnimations: true,
      ));
      await settle(tester);
    }

    testWidgets('fullscreen: the stage drops its safe areas and reaches the screen edges; the bar keeps its own',
        (tester) async {
      hasKey = true;
      s.overview = false;
      await pumpIosInsets(tester);
      final inset = tester.getRect(find.byKey(const Key('stage')));
      expect(inset.left, greaterThanOrEqualTo(20));
      expect(inset.right, lessThanOrEqualTo(1194 - 30));
      expect(inset.bottom, lessThanOrEqualTo(834 - 20));
      await tester.tap(find.byKey(const Key('fullscreen-button')));
      await settle(tester);
      expect(fs.calls, [true]);
      final full = tester.getRect(find.byKey(const Key('stage')));
      expect(full.left, 0);
      expect(full.right, 1194);
      expect(full.bottom, 834);
      final bar = tester.getRect(find.byType(TopBar));
      expect(bar.left, greaterThanOrEqualTo(20), reason: 'the top bar still clears the camera side');
      expect(bar.right, lessThanOrEqualTo(1194 - 30));
      // And back.
      await tester.tap(find.byKey(const Key('fullscreen-button')));
      await settle(tester);
      expect(fs.calls, [true, false]);
      expect(tester.getRect(find.byKey(const Key('stage'))), inset);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    for (final on in [false, true]) {
      testWidgets('fullscreen ${on ? 'on' : 'off'}: the soft keyboard never resizes the stage (Z1)', (tester) async {
        hasKey = true;
        s.overview = false;
        fs.on = on;
        await pumpIosInsets(tester);
        final down = tester.getRect(find.byKey(const Key('stage')));
        expect(down.bottom, on ? 834 : lessThanOrEqualTo(834 - 20));
        await pumpIosInsets(tester, keyboard: true);
        expect(tester.getRect(find.byKey(const Key('stage'))), down);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  testWidgets('desktop: a device page has its 端口 section', (tester) async {
    await pump(tester);
    s.showDevice('111');
    await settle(tester);
    expect(find.byKey(const ValueKey('shares-111')), findsOneWidget);
  });

  Future<void> pumpInsets(WidgetTester tester, MediaQueryData Function(MediaQueryData) edit) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(
      Builder(
        builder: (context) => MediaQuery(
          data: edit(MediaQuery.of(context)),
          child: MainWindow(state: s, monitor: monitor, control: null, fullscreen: fs),
        ),
      ),
      disableAnimations: true,
    ));
    await settle(tester);
  }

  testWidgets('safe areas: the top bar clears the status bar and the camera side (iPad spec §7.2)', (tester) async {
    await pumpInsets(tester, (m) => m.copyWith(padding: const EdgeInsets.only(top: 24, left: 20)));
    final bar = tester.getRect(find.byType(TopBar));
    expect(bar.top, greaterThanOrEqualTo(24));
    expect(bar.left, greaterThanOrEqualTo(20));
    expect(tester.getRect(find.byKey(const Key('stage'))).left, greaterThanOrEqualTo(20));
  });

  testWidgets('safe areas: the stage clears the home bar and keeps its size with the soft keyboard up (Z1)',
      (tester) async {
    await pumpInsets(tester,
        (m) => m.copyWith(padding: const EdgeInsets.only(bottom: 20), viewPadding: const EdgeInsets.only(bottom: 20)));
    final down = tester.getRect(find.byKey(const Key('stage')));
    expect(down.bottom, lessThanOrEqualTo(834 - 20));
    // The keyboard up: Flutter takes the home bar out of the padding, never out of the view padding.
    await pumpInsets(tester, (m) => m.copyWith(
        padding: EdgeInsets.zero,
        viewPadding: const EdgeInsets.only(bottom: 20),
        viewInsets: const EdgeInsets.only(bottom: 300)));
    expect(tester.getRect(find.byKey(const Key('stage'))), down);
  });

  testWidgets('opening and closing the panel never changes the stage size', (tester) async {
    await pump(tester);
    final base = tester.getSize(find.byKey(const Key('stage')));
    for (final tab in [PanelTab.sessions, PanelTab.devices]) {
      s.togglePanel(tab);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SidePanel), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('stage'))), base);
      s.closePanel();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getSize(find.byKey(const Key('stage'))), base);
    }
  });

  testWidgets('every tappable control is at least 48 tall on a touch platform', (tester) async {
    await pump(tester);
    t.emit({'event': 'opened', 'sid': 7, 'id': '111', 'app': 'com.apple.Safari', 'path': 'lan'});
    await settle(tester);
    expect(s.sessionCount, 1);
    for (final tab in [PanelTab.devices, PanelTab.sessions]) {
      s.togglePanel(tab);
      if (s.panel != tab) s.togglePanel(tab);
      await settle(tester);
      final finder = find.byWidgetPredicate((w) =>
          w is ButtonStyleButton || w is IconButton || w is InkWell || w is DropdownButton || w is Switch);
      for (final e in finder.evaluate()) {
        final h = tester.getSize(find.byElementPredicate((x) => x == e)).height;
        if (e.widget is Switch) continue;
        if (e.widget.key == const Key('settings-fold') ||
            find.ancestor(of: find.byElementPredicate((x) => x == e), matching: find.byKey(const Key('global-settings'))).evaluate().isNotEmpty) {
          continue;
        }
        if (h < 48) {
          final a = <String>[];
          e.visitAncestorElements((x) {
            if (a.length < 40) a.add('${x.widget.runtimeType}');
            return true;
          });
          fail('${e.widget.runtimeType} ${e.widget.key} h=$h in $tab: $a');
        }
      }
      expect(tester.getSize(find.byKey(const Key('start-fullscreen'))).height, 48);
      if (tab == PanelTab.sessions) expect(find.byKey(const Key('session-111/com.apple.Safari')), findsOneWidget);
    }
  });

  testWidgets('window mode has no permanent element besides the top bar', (tester) async {
    await pump(tester);
    expect(find.byType(TopBar), findsOneWidget);
    expect(find.byKey(const Key('stage')), findsOneWidget);
    expect(find.byType(SidePanel), findsNothing);
  });

  testWidgets('fullscreen button toggles the fake', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('fullscreen-button')));
    await settle(tester);
    expect(fs.on, isTrue);
    await tester.tap(find.byKey(const Key('fullscreen-button')));
    await settle(tester);
    expect(fs.on, isFalse);
  });

  testWidgets('Esc closes the panel first, then leaves fullscreen', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('fullscreen-button')));
    await settle(tester);
    s.togglePanel();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.panel, isNull);
    expect(fs.on, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(fs.on, isFalse);
  });

  testWidgets('ctrl+cmd+O toggles overview', (tester) async {
    await pump(tester);
    final mods = Platform.isMacOS
        ? [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.metaLeft]
        : [LogicalKeyboardKey.controlLeft];
    Future<void> chord({int repeats = 0}) async {
      for (final m in mods) {
        await tester.sendKeyDownEvent(m);
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyO);
      for (var i = 0; i < repeats; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyO);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyO);
      for (final m in mods.reversed) {
        await tester.sendKeyUpEvent(m);
      }
      await tester.pump();
    }

    expect(s.overview, false);
    await chord(repeats: 3);
    expect(s.overview, true);
    await chord();
    expect(s.overview, false);
  });

  testWidgets('更多 opens the log screen under the top bar; log-back returns; Esc order', (tester) async {
    await pump(tester, h: 1600);
    s.togglePanel(PanelTab.devices);
    await settle(tester);
    await tester.tap(find.byKey(const Key('access-log-more')));
    await settle(tester);
    expect(s.logs, true);
    expect(s.panel, isNull);
    expect(find.byType(LogScreen), findsOneWidget);
    expect(find.byType(TopBar), findsOneWidget);
    final first = tester.widget<LogScreen>(find.byType(LogScreen)).model;
    await tester.tap(find.byKey(const Key('log-back')));
    await settle(tester);
    expect(s.logs, false);
    expect(find.byType(LogScreen), findsNothing);
    // Esc: corner, panel, the log screen, then the overview underneath.
    s.toggleOverview();
    s.openLogs();
    s.togglePanel();
    s.toggleCorner(Corner.needs);
    await settle(tester);
    final second = tester.widget<LogScreen>(find.byType(LogScreen)).model;
    expect(second, isNot(same(first)), reason: 'a fresh model per opening');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.corner, isNull);
    expect(s.panel, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.panel, isNull);
    expect(s.logs, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.logs, false);
    expect(s.overview, true);
    expect(find.byType(LogScreen), findsNothing);
    expect(() => second.addListener(() {}), throwsA(anything), reason: 'closing disposes the model');
    expect(() => first.addListener(() {}), throwsA(anything));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.overview, false);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('esc leaves overview after corners and panel', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('fullscreen-button')));
    await settle(tester);
    s.togglePanel();
    s.toggleOverview();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.panel, isNull);
    expect(s.overview, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.overview, false);
    expect(fs.on, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(fs.on, isFalse);
  });

  testWidgets('escape closes the corner, then the panel, then fullscreen', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('fullscreen-button')));
    await settle(tester);
    s.togglePanel();
    s.toggleCorner(Corner.needs);
    await tester.pump();
    expect(find.byKey(const Key('needs-scrim')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.corner, isNull);
    expect(s.panel, isNotNull);
    expect(fs.on, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.panel, isNull);
    expect(fs.on, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(fs.on, isFalse);
  });

  testWidgets('tapping the scrim closes the panel', (tester) async {
    await pump(tester);
    s.togglePanel();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(900, 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.panel, isNull);
  });

  testWidgets('narrow window shows the latest hint under the top bar', (tester) async {
    openError = 'boom failure';
    await pump(tester, w: 360, h: 700);
    await tester.runAsync(() => s.openOrSwitch('111', 'com.apple.Safari', 'Safari'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hint, contains('boom failure'));
    expect(find.text(s.hint), findsOneWidget);
  });

  testWidgets('wide window does not duplicate the hint', (tester) async {
    openError = 'boom failure';
    await pump(tester);
    await tester.runAsync(() => s.openOrSwitch('111', 'com.apple.Safari', 'Safari'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(s.hint), findsOneWidget);
  });

  testWidgets('Esc in window mode closes the panel and leaves fullscreen alone', (tester) async {
    await pump(tester);
    s.togglePanel();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(s.panel, isNull);
    expect(fs.calls, isEmpty);
  });

  testWidgets('Esc with no panel in window mode does nothing', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(fs.calls, isEmpty);
    expect(s.panel, isNull);
  });

  testWidgets('fullscreen shortcut toggles the fake', (tester) async {
    await pump(tester);
    Future<void> chord() async {
      if (Platform.isMacOS) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      }
      await settle(tester);
    }

    await chord();
    expect(fs.on, isTrue);
    await chord();
    expect(fs.on, isFalse);
  });

  testWidgets('ctrl-cmd brackets step sessions; cmd brackets no longer do', (tester) async {
    await pump(tester);
    t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'A', 'path': 'lan'});
    t.emit({'event': 'opened', 'sid': 2, 'id': '111', 'app': 'B', 'path': 'lan'});
    await settle(tester);
    s.select('111/A');
    await tester.pump();
    Future<void> press(List<LogicalKeyboardKey> mods, LogicalKeyboardKey k) async {
      for (final m in mods) {
        await tester.sendKeyDownEvent(m);
      }
      await tester.sendKeyEvent(k);
      for (final m in mods.reversed) {
        await tester.sendKeyUpEvent(m);
      }
      await tester.pump();
    }

    final chord = Platform.isMacOS
        ? [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.metaLeft]
        : [LogicalKeyboardKey.controlLeft];
    await press(chord, LogicalKeyboardKey.bracketRight);
    expect(s.currentKey, '111/B');
    await press(chord, LogicalKeyboardKey.bracketLeft);
    expect(s.currentKey, '111/A');
    if (Platform.isMacOS) {
      // ⌘[ and ⌘] belong to A now.
      await press([LogicalKeyboardKey.metaLeft], LogicalKeyboardKey.bracketRight);
      expect(s.currentKey, '111/A');
      await press([LogicalKeyboardKey.metaLeft], LogicalKeyboardKey.bracketLeft);
      expect(s.currentKey, '111/A');
    }
  });

  testWidgets('ctrl-cmd-D toggles both ways', (tester) async {
    final port = FakeSessionPort();
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    final base = t.onSend!;
    t.onSend = (cmd) {
      if (cmd['cmd'] != 'open') return base(cmd);
      t.emit({
        'event': 'opened', 'req': cmd['req'], 'sid': 1, 'id': cmd['id'], 'app': cmd['app'], 'path': 'lan',
        'port': 5001, 'token': 'tk',
      });
    };
    await pump(tester);
    await tester.runAsync(() async {
      s.openOrSwitch('111', 'com.apple.calculator', 'Calculator');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    port.emit(const ReadyEvent(1, 'Calculator'));
    port.emit(WindowsEvent(1, [
      RemoteWindow(
        id: 7, parent: 0, kind: WindowKind.normal, title: 'w7', rect: const Rect.fromLTWH(0, 0, 400, 328),
        titleBar: 28, resizable: true, focused: false, texture: 7, visible: const Rect.fromLTWH(0, 0, 1, 1),
      ),
    ]));
    await tester.pump();
    Future<void> chord() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    // Records compare their maps by identity: match the call by its parts. The picture's focus
    // (it holds the keys by itself, and lets them go when detached) is not what is looked at.
    void last(String method) {
      final c = port.calls.lastWhere((c) => c.$1 != 'picture_focus');
      expect(c.$1, method);
      // detach also hands over the draft it is leaving with: empty here, nothing was typed.
      expect(
        c.$2,
        equals(method == 'detach' ? {'sid': 1, 'text': '', 'blocks': <Object>[]} : {'sid': 1}),
      );
    }

    // Holding the chord: the key repeats toggle nothing more.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyD);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    last('detach');
    expect(port.calls.where((c) => c.$1 == 'detach' || c.$1 == 'attach').length, 1);
    port.emit(const DetachedEvent(1, true));
    await tester.pump();
    await chord();
    last('attach');
    port.emit(const DetachedEvent(1, false));
    await tester.pump();
    // The 本机 menu's 会话 group offers the same toggle (the 流量 one when the bar is narrow).
    final local = find.byKey(const Key('session-menu'));
    await tester.tap(local.evaluate().isNotEmpty ? local : find.byKey(const Key('traffic')));
    await tester.pump();
    await tester.ensureVisible(find.text('分离成独立窗口'));
    await tester.tap(find.text('分离成独立窗口'));
    await tester.pump();
    last('detach');
  }, skip: !Platform.isMacOS);

  testWidgets('fullscreen state follows the OS', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('fullscreen-button')));
    await settle(tester);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    fs.osSet(false);
    await settle(tester);
    expect(find.byTooltip('进入全屏'), findsOneWidget);
    fs.calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(fs.calls, isEmpty);
  });

  testWidgets('fullscreen button stays at the right edge whatever the hint', (tester) async {
    await pump(tester);
    double right() => tester.getTopRight(find.byKey(const Key('fullscreen-button'))).dx;
    final empty = right();
    expect(empty, greaterThan(1194 - 60));
    openError = 'offline';
    await s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.hint, isNotEmpty);
    expect(right(), empty);
  });

  testWidgets('overview replaces the stage and back', (tester) async {
    await pump(tester);
    expect(find.byType(Stage), findsOneWidget);
    expect(find.byType(Overview), findsNothing);
    s.toggleOverview();
    await tester.pump();
    expect(find.byType(Overview), findsOneWidget);
    expect(find.byType(Stage), findsNothing);
    s.toggleOverview();
    await tester.pump();
    expect(find.byType(Overview), findsNothing);
    expect(find.byType(Stage), findsOneWidget);
  });

  testWidgets('a panel opens over the overview', (tester) async {
    await pump(tester);
    s.toggleOverview();
    await tester.pump();
    final wall = tester.getSize(find.byKey(const Key('wall')));
    s.togglePanel();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('scrim')), findsOneWidget);
    expect(find.byType(SidePanel), findsOneWidget);
    expect(find.byType(Overview), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('wall'))), wall);
  });

  testWidgets('Ctrl+Enter opens the panel and moves the caret back and forth', (tester) async {
    s.dispose();
    final port = FakeSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    await pump(tester);
    await tester.runAsync(() async {
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          t.emit({
            'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            'port': 5001, 'token': 'tk', 'req': m['req'],
          });
        }
      };
      s.openOrSwitch('111', 'Safari', 'Safari');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    port.emit(const ReadyEvent(1, 'Safari'));
    port.emit(WindowsEvent(1, [
      const RemoteWindow(
        id: 5, parent: 0, kind: WindowKind.normal, title: 'w', rect: Rect.fromLTWH(0, 0, 800, 600),
        titleBar: 28, resizable: true, focused: true, texture: 42, visible: Rect.fromLTWH(0, 0, 1, 1),
      ),
    ]));
    await tester.pump();
    await tester.pump();

    Future<void> ctrlEnter() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));
    }

    bool pictureHasFlutterFocus() => tester
        .widget<Focus>(find.descendant(of: find.byType(Picture), matching: find.byType(Focus)).first)
        .focusNode!
        .hasFocus;
    bool editorHasFocus() => tester.widget<TextField>(find.byKey(const Key('composer-field'))).focusNode!.hasFocus;

    // 1: closed -> the panel appears with the caret in it.
    await ctrlEnter();
    expect(find.byType(ComposerPanel), findsOneWidget);
    expect(editorHasFocus(), true);

    // 2: editor -> picture.
    await ctrlEnter();
    expect(editorHasFocus(), false);
    expect(s.pictureFocused, 1);
    expect(pictureHasFlutterFocus(), true);
    expect(find.byKey(const Key('picture-focus')), findsOneWidget);
    expect(find.byType(ComposerPanel), findsOneWidget);
    expect(port.calls.where((c) => c.$1 == 'picture_focus').last.$2, {'sid': 1, 'compose': true});

    // 3: picture -> editor again; nothing typed, nothing sent.
    await ctrlEnter();
    expect(editorHasFocus(), true);
    expect(s.pictureFocused, isNull);
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, '');
    expect(port.calls.where((c) => c.$1 == 'composer_send'), isEmpty);
    expect(pictureHasFlutterFocus(), false);

    // The guard: keys to the picture while the editor still holds the caret leave Flutter's focus alone.
    s.focusPicture(1);
    await tester.pump();
    await tester.pump();
    expect(editorHasFocus(), true);
    expect(pictureHasFlutterFocus(), false);
  });

  testWidgets('composer draft survives a trip through overview', (tester) async {
    s.dispose();
    final port = FakeSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    await pump(tester);
    await tester.runAsync(() async {
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          t.emit({
            'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            'port': 5001, 'token': 'tk', 'req': m['req'],
          });
        }
      };
      s.openOrSwitch('111', 'Safari', 'Safari');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    port.emit(const ReadyEvent(1, 'Safari'));
    port.emit(WindowsEvent(1, [
      const RemoteWindow(
        id: 5,
        parent: 0,
        kind: WindowKind.normal,
        title: 'w',
        rect: Rect.fromLTWH(0, 0, 800, 600),
        titleBar: 28,
        resizable: true,
        focused: true,
        texture: 42,
        visible: Rect.fromLTWH(0, 0, 1, 1),
      ),
    ]));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump(const Duration(milliseconds: 100));
    // Typed into the editor: the trip's collapse of the panel copies it into the draft.
    await tester.enterText(find.byKey(const Key('composer-field')), 'draft text');
    s.toggleOverview();
    await tester.pump();
    expect(find.byType(ComposerPanel), findsNothing);
    expect(s.currentRemote!.composer.draft, 'draft text');
    s.toggleOverview();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ComposerPanel), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, 'draft text');
  });

  // Fullscreen, a session with a picture, the writing panel open with the caret in it.
  Future<void> panelInFullscreen(WidgetTester tester) async {
    s.dispose();
    final port = FakeSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    await pump(tester);
    await tester.tap(find.byKey(const Key('fullscreen-button')));
    await tester.pump();
    expect(fs.on, isTrue);
    await tester.runAsync(() async {
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          t.emit({
            'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            'port': 5001, 'token': 'tk', 'req': m['req'],
          });
        }
      };
      s.openOrSwitch('111', 'Safari', 'Safari');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    port.emit(const ReadyEvent(1, 'Safari'));
    port.emit(WindowsEvent(1, [
      const RemoteWindow(
        id: 5,
        parent: 0,
        kind: WindowKind.normal,
        title: 'w',
        rect: Rect.fromLTWH(0, 0, 800, 600),
        titleBar: 28,
        resizable: true,
        focused: true,
        texture: 42,
        visible: Rect.fromLTWH(0, 0, 1, 1),
      ),
    ]));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ComposerPanel), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).focusNode!.hasFocus, isTrue);
    fs.calls.clear();
  }

  testWidgets('in fullscreen the panel is there; Esc in it collapses the panel and stays fullscreen', (tester) async {
    await panelInFullscreen(tester);
    // Esc in the editor is the panel's: it collapses, fullscreen stays.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(ComposerPanel), findsNothing);
    expect(fs.calls, isEmpty);
    expect(fs.on, isTrue);
    // The focus is no longer in the editor: the next Esc is the window's.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fs.calls, [false]);
    expect(fs.on, isFalse);
  });

  testWidgets('a held Esc collapses the panel and never leaves fullscreen (m2)', (tester) async {
    await panelInFullscreen(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(ComposerPanel), findsNothing);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fs.calls, isEmpty);
    expect(fs.on, isTrue);
  });
}
