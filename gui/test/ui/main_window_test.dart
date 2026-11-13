import 'dart:async';
import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_bar.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/fullscreen.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/side_panel.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
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
      MainWindow(state: s, monitor: monitor, control: null, data: DataDir(tmp.path), fullscreen: fs),
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

  testWidgets('every tappable control is at least 48 tall', (tester) async {
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
        if (h < 48) {
          final a = <String>[];
          e.visitAncestorElements((x) {
            if (a.length < 40) a.add('${x.widget.runtimeType}');
            return true;
          });
          fail('${e.widget.runtimeType} ${e.widget.key} h=$h in $tab: $a');
        }
      }
      expect(tester.getSize(find.byKey(const Key('start-fullscreen'))).height, greaterThanOrEqualTo(48));
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

    // Records compare their maps by identity: match the call by its parts.
    void last(String method) {
      expect(port.calls.last.$1, method);
      expect(port.calls.last.$2, equals({'sid': 1}));
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
    // The stream menu's 会话 group offers the same toggle.
    await tester.tap(find.byKey(const Key('traffic')));
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
    s.currentRemote!.composer.text = 'draft text';
    s.toggleOverview();
    await tester.pump();
    expect(find.byType(ComposerBar), findsNothing);
    s.toggleOverview();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ComposerBar), findsOneWidget);
    expect(s.currentRemote!.composer.text, 'draft text');
    expect(find.text('draft text'), findsOneWidget);
  });
}
