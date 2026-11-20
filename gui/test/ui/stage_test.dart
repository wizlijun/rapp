import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:rapp/paths.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart' show AfterSend, RuleAction, WindowRule;
import 'package:rapp/embed/flutter_editor.dart' show FlutterEditor;
import 'package:rapp/embed/composer_model.dart' show escKeyCode;
import 'package:rapp/embed/geometry.dart' show contentSize, fitRect, toRemote;
import 'package:rapp/embed/picture.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/fullscreen.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/backdrop.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/disconnected_stage.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/lifecycle.dart' show Phase;
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/embed/composer_panel.dart' show composerFillOpacity, seeThroughBox;
import 'package:rapp/embed/key_bar.dart' show keyBarHeightOf;
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import 'helpers.dart';
import 'platform_helpers.dart';

class _KeyboardPort extends FakeSessionPort {
  final keys = <KeyEvent>[];
  @override
  bool handleKeyEvent(Object sid, KeyEvent event) { keys.add(event); return true; }
}

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('stage_test');
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

  Widget stage() => SizedBox(width: 800, height: 600, child: Stage(state: s));

  Future<void> openActive(WidgetTester tester) async {
    await tester.runAsync(() async {
      t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'Safari', 'path': 'lan'});
      await flush();
    });
    s.select('111/Safari');
    await tester.pump();
  }

  testWidgets('empty stage invites opening the panel', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    expect(find.text('打开左侧面板，选一个会话或到设备里打开 app'), findsOneWidget);
    await tester.tap(find.text('打开面板'));
    expect(s.panel, isNotNull);
  });

  testWidgets('stage placeholder focus button sends focus', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    await openActive(tester);
    expect(find.text('Safari 在单独的窗口里 · mini · 局域网'), findsOneWidget);
    await tester.tap(find.byKey(const Key('focus-button')));
    expect(t.sent.last, {'cmd': 'focus', 'sid': 1});
  });

  testWidgets('end button needs two taps', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    await openActive(tester);
    await tester.tap(find.byKey(const Key('end-button')));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
    await tester.tap(find.byKey(const Key('end-button')));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'close').single, {'cmd': 'close', 'sid': 1});
  });

  testWidgets('armed end button does not carry over to the next session', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    await tester.runAsync(() async {
      t.emit({'event': 'opened', 'sid': 2, 'id': '111', 'app': 'Notes', 'path': 'lan'});
      await flush();
    });
    await openActive(tester);
    await tester.tap(find.byKey(const Key('end-button')));
    await tester.pump();
    expect(find.text('再点一次确认'), findsOneWidget);
    await tester.runAsync(() async {
      t.emit({'event': 'closed', 'sid': 1, 'reason': 'app quit'});
      await flush();
    });
    await tester.pump();
    expect(s.current?.appName, 'Notes');
    expect(find.text('再点一次确认'), findsNothing);
    await tester.tap(find.byKey(const Key('end-button')));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
  });

  testWidgets('stage shows connecting while open is pending', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    s.openOrSwitch('111', 'Safari', 'Safari');
    await tester.pump(const Duration(milliseconds: 100));
    final lamp = tester.widget<StatusLamp>(find.byType(StatusLamp));
    expect(lamp.kind, Lamp.connecting);
    expect(find.text('正在连接'), findsOneWidget);
  });

  testWidgets('stage shows hub problem after hub dies', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    await openActive(tester);
    await tester.runAsync(() async {
      await t.die();
      await flush();
    });
    await tester.pump();
    expect(find.text('rapp-hub 已退出 — 重启 rapp 以恢复'), findsOneWidget);
    expect(find.byKey(const Key('focus-button')), findsNothing);
  });

  for (final th in RappTheme.values) {
    testWidgets('backdrop ${th.name} keeps child and ignores pointers', (tester) async {
      await tester.pumpWidget(wrap(
        SizedBox(width: 300, height: 200, child: Backdrop(theme: th, child: const Text('hi'))),
        theme: th,
      ));
      expect(find.text('hi'), findsOneWidget);
      if (th != RappTheme.westworld) {
        expect(find.descendant(of: find.byType(Backdrop), matching: find.byType(IgnorePointer)),
            findsWidgets);
      }
    });
  }

  group('embedded', () {
    late FakeSessionPort port;
    late MainState es;

    RemoteWindow rw(int id, double w, double h, {int? texture = 42}) => RemoteWindow(
          id: id,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w$id',
          rect: Rect.fromLTWH(0, 0, w, h),
          titleBar: 28,
          resizable: true,
          focused: true,
          texture: texture,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    Future<void> openEmbedded(WidgetTester tester, {String app = 'Safari'}) async {
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5001, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.openOrSwitch('111', app, app);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
    }

    setUp(() {
      port = FakeSessionPort();
      es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    });
    tearDown(() => es.dispose());

    Widget embedded({RappTheme theme = RappTheme.matrix}) => SizedBox(
          width: 800,
          height: 600,
          child: Backdrop(theme: theme, child: Stage(state: es, composerEditor: FlutterEditor.new)),
        );

    for (final app in ['com.apple.Terminal', 'Safari']) {
      testWidgets('iOS $app picture: lifted by its bar only, open or closed${app == 'Safari' ? ' (Safari: none)' : ''}',
          (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await tester.pumpWidget(wrap(embedded()));
          await openEmbedded(tester, app: app);
          port.emit(ReadyEvent(1, app));
          port.emit(WindowsEvent(1, [rw(7, 400, 328)]));
          await tester.pump();
          await tester.pump();
          final lifts = find.ancestor(of: find.byKey(const Key('stage')), matching: find.byType(Transform));
          double lift() => lifts.evaluate().isEmpty
              ? 0
              : -tester.widget<Transform>(lifts.first).transform.getTranslation().y;
          final rs = es.remote[1]!;
          final bar = keyBarHeightOf(es, rs, 800);
          expect(lift(), app == 'Safari' ? 0 : bar);
          rs.composer.open = true;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(lift(), app == 'Safari' ? 0 : bar); // an app: the bar only, open or closed
          rs.composer.collapse();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(lift(), app == 'Safari' ? 0 : bar);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('stage shows connecting, then the texture', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester);
      expect(find.text('正在连接'), findsOneWidget);
      port.emit(const ReadyEvent(1, 'Safari'));
      await tester.pump();
      expect(find.text('正在连接'), findsOneWidget);
      port.emit(WindowsEvent(1, [rw(5, 400, 328)]));
      await tester.pump();
      expect(find.text('正在连接'), findsNothing);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
    });

    testWidgets('Linux image renders in the stage and picture owns keyboard focus', (tester) async {
      es.dispose();
      final keyboard = _KeyboardPort();
      port = keyboard;
      es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.red, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(4, 4));
      picture.dispose();
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Fixture'));
      port.emit(WindowsEvent(1, [RemoteWindow(id: 1, parent: 0, kind: WindowKind.normal,
          title: 'Window', rect: const Rect.fromLTWH(0,0,400,300), titleBar: 0,
          resizable: false, focused: true, texture: null, visible: const Rect.fromLTWH(0,0,1,1),
          image: image, source: const Rect.fromLTWH(0,0,4,4))]));
      await tester.pump();
      expect(find.text('正在连接'), findsNothing);
      expect(find.byType(Texture), findsNothing);
      final first = await tester.startGesture(const Offset(320, 300), pointer: 51, kind: PointerDeviceKind.touch);
      final second = await tester.startGesture(const Offset(380, 300), pointer: 52, kind: PointerDeviceKind.touch);
      await first.moveBy(const Offset(0, -20));
      await second.moveBy(const Offset(0, -20));
      await first.up(); await second.up();
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'scroll').length, 2);
      expect(port.calls.where((c) => c.$1 == 'mouse'), isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      expect(keyboard.keys.map((e) => e.logicalKey), contains(LogicalKeyboardKey.keyB));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(keyboard.keys.map((e) => e.logicalKey), containsAll([LogicalKeyboardKey.escape, LogicalKeyboardKey.keyA]));
      expect(es.pictureFocused, 1);
      expect(port.calls.where((c) => c.$1 == 'mouse').length, 2);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(DisconnectedStage), findsOneWidget);
      expect(
          tester
              .widgetList<CustomPaint>(
                  find.descendant(of: find.byType(DisconnectedStage), matching: find.byType(CustomPaint)))
              .any((c) => c.painter.runtimeType.toString() == '_FramePainter'),
          isTrue,
          reason: 'Linux last-frame surface remains visible');
      expect(es.pictureFocused, isNull);
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5011, 'token': 'tk', 'req': m['req']});
          }
        };
        await tester.tap(find.byKey(const Key('reconnect-button')));
        for (var i = 0; i < 4; i++) { await flush(); }
      });
      await tester.pump();
      expect(es.currentRecord!.lastSid, 1);
      port.emit(const ReadyEvent(11, 'Fixture'));
      port.emit(WindowsEvent(11, es.remote[1]!.windows));
      await tester.pump();
      expect(es.currentRecord!.lastSid, isNull);
      expect(find.byType(DisconnectedStage), findsNothing);
      expect(find.byType(Picture), findsOneWidget);
      expect(port.calls.where((c) => c.$1 == 'close' && c.$2['sid'] == 1).length, 1);
      await tester.pumpWidget(const SizedBox());
      image!.dispose();
    });

    testWidgets('stage size goes to A once the window settles', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 400, 328)]));
      await tester.pump();
      final r = port.calls.where((c) => c.$1 == 'resize').toList();
      expect(r.length, 1);
      expect(r.single.$2, equals({'sid': 1, 'window': 5, 'w': 800, 'h': 600}));
    });

    testWidgets('detached placeholder shows the words and buttons', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester, app: 'Calculator');
      port.emit(const ReadyEvent(1, 'Calculator'));
      port.emit(WindowsEvent(1, [rw(5, 400, 328)]));
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
      port.emit(const DetachedEvent(1, true));
      await tester.pump();
      expect(find.byType(Texture), findsNothing);
      expect(find.text('Calculator 在单独的窗口里 · mini · 局域网'), findsOneWidget);
      // Collapsed, the composer is a keyboard icon; 输入 is its name for assistive tech.
      expect(find.text('输入'), findsNothing);
      expect(find.descendant(of: find.byKey(const Key('composer-open')), matching: find.byIcon(Icons.keyboard_outlined)),
          findsOneWidget);
      expect(find.bySemanticsLabel('输入'), findsOneWidget);
      // Records compare their maps by identity: match the call by its parts.
      void last(String method) {
        expect(port.calls.last.$1, method);
        expect(port.calls.last.$2, equals({'sid': 1}));
      }

      await tester.tap(find.text('切到窗口'));
      await tester.pump();
      last('raise_detached');
      expect(t.sent.where((m) => m['cmd'] == 'focus'), isEmpty);
      await tester.tap(find.text('放回主窗口'));
      await tester.pump();
      last('attach');
      await tester.tap(find.text('结束会话'));
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'close'), isEmpty);
      await tester.tap(find.text('再点一次确认'));
      await tester.pump();
      last('close');
      // The runner's answer to 放回: the picture is back.
      port.emit(const DetachedEvent(1, false, current: 5));
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
      expect(find.text('放回主窗口'), findsNothing);
    });

    Future<void> shown(WidgetTester tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 400, 328)]));
      port.emit(const TrafficEvent(1, 100, 1));
      await tester.pump();
    }

    final tex42 = find.byWidgetPredicate((w) => w is Texture && w.textureId == 42);

    testWidgets('a taken over session offers 拿回来', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'host says: taken over by M'));
      await tester.pump();
      expect(tester.widget<RappButton>(find.byKey(const Key('reconnect-button'))).label, '拿回来');
      expect(tester.widget<Text>(find.byKey(const Key('disconnect-reason'))).data, '这个窗口在 M 上打开了');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('reconnect-button')));
        await flush();
      });
      await tester.pump();
      expect(t.sent.last['cmd'], 'open');
      expect(t.sent.last['reconnect'], true);
    });

    testWidgets('disconnected shows the last frame, stripes and reconnect', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      expect(tex42, findsOneWidget);
      expect(find.byKey(const Key('reconnect-button')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('disconnect-reason'))).data, '你断开了');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('reconnect-button')));
        await flush();
      });
      await tester.pump();
      expect(t.sent.last['reconnect'], true);
    });

    testWidgets('disconnected picture takes no input', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      port.calls.clear();
      await tester.tapAt(tester.getTopLeft(find.byKey(const Key('stage'))) + const Offset(40, 40));
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'mouse'), isEmpty);
      expect(port.calls.where((c) => c.$1 == 'picture_focus'), isEmpty);
      expect(es.pictureFocused, isNull);
    });

    testWidgets('a network drop keeps the picture with a bar, not the disconnected stage', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      expect(find.byType(DisconnectedStage), findsNothing);
      expect(find.byType(Picture), findsOneWidget);
      expect(tex42, findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('offline-text'))).data, '网络断了，正在重连…');
      expect(find.byKey(const Key('stop-reconnect-button')), findsOneWidget);
      expect(find.byKey(const Key('disconnected-end-button')), findsNothing);
      await tester.tap(find.byKey(const Key('stop-reconnect-button')));
      await tester.pump();
      expect(es.currentRecord!.retry, isNull);
      expect(find.byKey(const Key('reconnect-button')), findsOneWidget);
    });

    testWidgets('a frozen picture takes no input and never resizes', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      port.calls.clear();
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      await tester.tapAt(o + const Offset(200, 200));
      await tester.sendEventToBinding(PointerScrollEvent(position: o + const Offset(200, 200), scrollDelta: const Offset(0, 40)));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pumpWidget(wrap(SizedBox(width: 700, height: 500, child: Backdrop(theme: RappTheme.matrix, child: Stage(state: es)))));
      await tester.pump(const Duration(milliseconds: 400)); // past the policy's 300 ms
      for (final m in ['mouse', 'scroll', 'key', 'picture_focus', 'resize']) {
        expect(port.calls.where((c) => c.$1 == m), isEmpty, reason: m);
      }
      expect(es.pictureFocused, isNull);
    });

    testWidgets('a mouse drag in flight at the drop sends nothing more', (tester) async {
      await shown(tester);
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(o + const Offset(300, 250));
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      port.calls.clear();
      await g.moveBy(const Offset(10, 0));
      await g.up();
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'mouse' || c.$1 == 'scroll'), isEmpty);
    });

    testWidgets('a held-back touch press is dropped at the drop', (tester) async {
      await shown(tester);
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final f = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
      await f.down(o + const Offset(300, 250));
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      port.calls.clear();
      await tester.pump(const Duration(milliseconds: 300));
      await f.up();
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'mouse'), isEmpty);
    });

    testWidgets('a resize timer started just before the drop never fires', (tester) async {
      await shown(tester);
      port.calls.clear();
      await tester.pumpWidget(wrap(SizedBox(width: 700, height: 500, child: Backdrop(theme: RappTheme.matrix, child: Stage(state: es)))));
      await tester.pump(const Duration(milliseconds: 100));
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    });

    testWidgets('the picture element survives the drop', (tester) async {
      await shown(tester);
      final before = tester.element(find.byType(Picture));
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      expect(identical(tester.element(find.byType(Picture)), before), isTrue);
    });

    testWidgets('a non-network drop still shows the disconnected stage', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'bad password'));
      await tester.pump();
      expect(find.byType(DisconnectedStage), findsOneWidget);
      expect(find.byKey(const Key('offline-bar')), findsNothing);
    });

    testWidgets('first-open failure shows reconnect without a frame', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'not trusted'});
        };
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      expect(find.byType(Texture), findsNothing);
      expect(find.byKey(const Key('reconnect-button')), findsOneWidget);
    });

    testWidgets('a first-open network failure waits with stop instead of reconnect', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'cannot reach the host'});
        };
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      expect(find.byKey(const Key('stop-reconnect-button')), findsOneWidget);
      es.stopReconnectCurrent();
      await tester.pump();
      expect(find.byKey(const Key('reconnect-button')), findsOneWidget);
    });

    testWidgets('a first-open failure is ended from the stage with two taps', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'bad password'});
        };
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      expect(es.sessionCount, 1);
      expect(es.needCount, 1);
      final end = find.byKey(const Key('disconnected-end-button'));
      expect(end, findsOneWidget);
      await tester.tap(end);
      await tester.pump();
      expect(es.sessionCount, 1); // armed, not yet
      await tester.tap(end);
      await tester.pump();
      expect(es.sessionCount, 0);
      expect(es.recordFor('111/Safari'), isNull);
      expect(es.needCount, 0);
      expect(find.byType(DisconnectedStage), findsNothing);
    });

    testWidgets('an armed disconnected end does not carry over to the next session', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'offline'});
        };
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
        es.openOrSwitch('111', 'Notes', 'Notes');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      final end = find.byKey(const Key('disconnected-end-button'));
      await tester.tap(end);
      await tester.pump();
      expect(find.text('再点一次确认'), findsOneWidget);
      es.select('111/Safari');
      await tester.pump();
      expect(find.text('再点一次确认'), findsNothing);
      await tester.tap(end);
      await tester.pump();
      expect(es.sessionCount, 2);
    });

    testWidgets('a disconnected session with a frame also offers 结束会话; none while reconnecting', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      expect(find.byKey(const Key('disconnected-end-button')), findsOneWidget);
      t.onSend = (_) {}; // the reopen never answers
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('reconnect-button')));
        await flush();
      });
      await tester.pump();
      expect(find.byKey(const Key('disconnected-end-button')), findsNothing);
    });

    testWidgets('reconnecting keeps the old frame with a connecting lamp', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      t.onSend = (_) {}; // the reopen never answers
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('reconnect-button')));
        await flush();
      });
      await tester.pump();
      expect(tex42, findsOneWidget);
      expect(find.text('正在连接'), findsOneWidget);
      expect(find.byKey(const Key('reconnect-button')), findsNothing);
    });

    testWidgets('reconnect opened but not swapped keeps stripes and takes no input', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5011, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        await tester.tap(find.byKey(const Key('reconnect-button')));
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      expect(es.currentRecord!.lastSid, 1);
      expect(find.byType(DisconnectedStage), findsOneWidget);
      expect(find.text('正在连接'), findsOneWidget);
      expect(tex42, findsOneWidget);
      port.calls.clear();
      await tester.tapAt(tester.getCenter(find.byKey(const Key('stage'))));
      await tester.pump();
      es.toggleDetach();
      expect(port.calls.where((c) => c.$1 == 'mouse' || c.$1 == 'detach' || c.$1 == 'picture_focus'), isEmpty);
    });

    testWidgets('a network drop freezes the record; a user disconnect does not', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      expect(es.currentRecord!.frozen, true);
      expect(es.sendBlocked(1), true);
      expect(es.sendBlocked(99), false);
      es.stopReconnectCurrent();
    });

    testWidgets('a user disconnect does not freeze', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      expect(es.currentRecord!.frozen, false);
      expect(es.sendBlocked(1), false);
    });

    group('the writing panel while frozen', () {
      final field = find.byKey(const Key('composer-field'));
      final send = find.byKey(const Key('composer-send'));
      String text(WidgetTester tester) => tester.widget<TextField>(field).controller!.text;

      Future<void> dropWithDraft(WidgetTester tester) async {
        await shown(tester);
        es.currentRemote!.composer.open = true;
        await tester.pump();
        await tester.pump();
        await tester.enterText(field, 'git push');
        await tester.pump();
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        await tester.pump();
      }

      Future<void> reconnect(WidgetTester tester) async {
        await tester.runAsync(() async {
          t.onSend = (m) {
            if (m['cmd'] == 'open') {
              t.emit({
                'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
                'port': 5011, 'token': 'tk', 'req': m['req'],
              });
            }
          };
          es.reconnectCurrent();
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        port.emit(const ReadyEvent(11, 'Safari'));
        port.emit(WindowsEvent(11, [rw(5, 400, 328)]));
        await tester.pump();
        await tester.pump();
      }

      List<String> sends() => [for (final c in port.calls) c.$1].where((m) => m == 'composer_send' || m == 'key').toList();

      testWidgets('a frozen panel keeps its text and greys 发送', (tester) async {
        await dropWithDraft(tester);
        expect(tester.widget<RappButton>(send).onPressed, isNull);
        await tester.enterText(field, 'git push origin');
        await tester.pump();
        expect(text(tester), 'git push origin');
        port.calls.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(sends(), isEmpty);
        expect(text(tester), 'git push origin');
      });

      testWidgets('直接回车 while frozen sends no Return', (tester) async {
        await dropWithDraft(tester);
        await tester.enterText(field, '');
        await tester.showKeyboard(field);
        await tester.pump();
        expect(es.currentRemote!.profile.afterSend, AfterSend.pressReturn);
        port.calls.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(sends(), isEmpty);
      });

      testWidgets('a frozen panel still pastes and attaches locally', (tester) async {
        await dropWithDraft(tester);
        await tester.showKeyboard(field);
        port.calls.clear();
        final mac = defaultTargetPlatform == TargetPlatform.macOS;
        final mod = mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(mod);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(mod);
        await tester.pump();
        expect(port.calls.where((c) => c.$1 == 'composer_paste'), isNotEmpty);
        await tester.tap(find.byKey(const Key('composer-plus')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('附件…'));
        await tester.pump();
        expect(port.calls.where((c) => c.$1 == 'composer_attach'), isNotEmpty);
        expect(sends(), isEmpty);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('a failed row while frozen: 重试 is grey, 放回输入框 works', (tester) async {
        await shown(tester);
        final rs = es.currentRemote!;
        rs.composer.open = true;
        await tester.pump();
        await tester.pump();
        await tester.enterText(field, 'hello');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        rs.apply(const ComposerStateEvent(1, done: ComposerDone(0, 'A 上贴不进去')));
        await tester.pump();
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        await tester.pump();
        expect(find.text('A 上贴不进去'), findsOneWidget);
        final retry = find.widgetWithText(RappButton, '重试');
        expect(tester.widget<RappButton>(retry).onPressed, isNull);
        await tester.tap(find.text('放回输入框'));
        await tester.pump();
        expect(text(tester), 'hello');
        expect(find.text('A 上贴不进去'), findsNothing);
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets('the frozen keys grid and copy send nothing', (tester) async {
        await dropWithDraft(tester);
        await tester.tap(find.byKey(const Key('composer-plus')));
        await tester.pumpAndSettle();
        port.calls.clear();
        await tester.tap(find.text('回车'));
        await tester.tap(find.text('在远端复制'));
        await tester.pump();
        expect(sends(), isEmpty);
      });

      testWidgets('the frozen draft comes back live after the swap', (tester) async {
        await dropWithDraft(tester);
        await tester.enterText(field, 'git push origin');
        await tester.pump();
        await reconnect(tester);
        expect(text(tester), 'git push origin');
        expect(tester.widget<RappButton>(send).onPressed, isNotNull);
        port.calls.clear();
        await tester.tap(send);
        await tester.pump();
        final c = port.calls.where((c) => c.$1 == 'composer_send').toList();
        expect(c.length, 1);
        expect(c.single.$2['sid'], 11);
      });

      testWidgets('a focused editor and an open panel survive the swap with the draft', (tester) async {
        await dropWithDraft(tester);
        await tester.showKeyboard(field);
        await tester.pump();
        expect(tester.widget<TextField>(field).focusNode!.hasPrimaryFocus, isTrue);
        await reconnect(tester);
        expect(es.currentRemote!.composer.open, isTrue);
        expect(field, findsOneWidget);
        expect(tester.widget<TextField>(field).focusNode!.hasPrimaryFocus, isTrue);
        expect(text(tester), 'git push');
      });

      testWidgets('Ctrl+Enter from the editor while frozen keeps the caret in the panel', (tester) async {
        await dropWithDraft(tester);
        await tester.showKeyboard(field);
        await tester.pump();
        expect(tester.widget<TextField>(field).focusNode!.hasPrimaryFocus, isTrue);
        es.composerKey();
        await tester.pump();
        await tester.pump();
        expect(tester.widget<TextField>(field).focusNode!.hasPrimaryFocus, isTrue);
        expect(es.currentRemote!.composer.open, isTrue);
        expect(es.pictureFocused, isNull);
      });

      int opens() => t.sent.where((m) => m['cmd'] == 'open').length;

      /// The bar after a 停止: frozen still, 重连 on it, the network words without 正在重连, no new try.
      Future<void> stoppedUnderTheBar(WidgetTester tester) async {
        expect(es.currentRecord!.phase, Phase.disconnected);
        expect(es.currentRecord!.frozen, isTrue);
        expect(es.currentRecord!.retry, isNull);
        expect(find.byType(DisconnectedStage), findsNothing);
        expect(find.byKey(const Key('offline-bar')), findsOneWidget);
        expect(find.byKey(const Key('reconnect-button')), findsOneWidget);
        expect(find.byKey(const Key('stop-reconnect-button')), findsNothing);
        expect(tester.widget<Text>(find.byKey(const Key('offline-text'))).data, '网络断了');
        expect(field, findsOneWidget);
        expect(text(tester), 'git push');
        final n = opens();
        await tester.pump(const Duration(seconds: 60));
        expect(opens(), n);
        expect(es.currentRecord!.retry, isNull);
      }

      /// 重连 on the bar: the new session (sid 11) swaps in under the same panel.
      Future<void> tapReconnect(WidgetTester tester) async {
        await tester.runAsync(() async {
          t.onSend = (m) {
            if (m['cmd'] == 'open') {
              t.emit({
                'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
                'port': 5011, 'token': 'tk', 'req': m['req'],
              });
            }
          };
          await tester.tap(find.byKey(const Key('reconnect-button')));
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        port.emit(const ReadyEvent(11, 'Safari'));
        port.emit(WindowsEvent(11, [rw(5, 400, 328)]));
        await tester.pump();
        await tester.pump();
        expect(es.currentRecord!.frozen, isFalse);
        expect(es.currentRemote!.sid, 11);
        expect(find.byKey(const Key('offline-bar')), findsNothing);
        expect(text(tester), 'git push');
        expect(tester.widget<RappButton>(send).onPressed, isNotNull);
      }

      testWidgets('停止 while an automatic try is opening keeps the frozen bar; 重连 then swaps in', (tester) async {
        await dropWithDraft(tester);
        Object? req;
        t.onSend = (m) {
          if (m['cmd'] == 'open') req = m['req'];
        };
        await tester.runAsync(() async {
          es.reconnect(es.currentKey!, auto: true);
          await flush();
        });
        await tester.pump();
        expect(es.currentRecord!.phase, Phase.connecting);
        await tester.tap(find.byKey(const Key('stop-reconnect-button')));
        await tester.pump();
        await tester.runAsync(() async {
          t.emit({'event': 'error', 'req': req, 'error': 'cannot reach the host'});
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        await stoppedUnderTheBar(tester);
        await tapReconnect(tester);
      });

      testWidgets('停止 while an automatic try is opening, then the open succeeds: still the frozen bar', (tester) async {
        await dropWithDraft(tester);
        Object? req;
        t.onSend = (m) {
          if (m['cmd'] == 'open') req = m['req'];
        };
        await tester.runAsync(() async {
          es.reconnect(es.currentKey!, auto: true);
          await flush();
        });
        await tester.pump();
        await tester.tap(find.byKey(const Key('stop-reconnect-button')));
        await tester.pump();
        await tester.runAsync(() async {
          t.emit({
            'event': 'opened', 'sid': 11, 'id': '111', 'app': 'Safari', 'path': 'lan',
            'port': 5011, 'token': 'tk', 'req': req,
          });
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 11), isNotEmpty);
        await stoppedUnderTheBar(tester);
      });

      testWidgets('停止 while an automatic try is starting keeps the frozen bar', (tester) async {
        await dropWithDraft(tester);
        port.startGate = Completer<void>();
        await tester.runAsync(() async {
          t.onSend = (m) {
            if (m['cmd'] == 'open') {
              t.emit({
                'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
                'port': 5011, 'token': 'tk', 'req': m['req'],
              });
            }
          };
          es.reconnect(es.currentKey!, auto: true);
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        expect(port.calls.where((c) => c.$1 == 'start' && c.$2['sid'] == 11), isNotEmpty);
        await tester.tap(find.byKey(const Key('stop-reconnect-button')));
        await tester.pump();
        await tester.runAsync(() async {
          port.startGate!.complete();
          port.startGate = null;
          for (var i = 0; i < 4; i++) {
            await flush();
          }
        });
        await tester.pump();
        expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 11), isNotEmpty);
        expect(es.currentRemote!.sid, 1);
        await stoppedUnderTheBar(tester);
        await tapReconnect(tester);
      });
    });

    testWidgets('停止 on a reconnect of a session that never froze still ends as 你断开了', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      expect(es.currentRecord!.frozen, isFalse);
      Object? req;
      t.onSend = (m) {
        if (m['cmd'] == 'open') req = m['req'];
      };
      await tester.runAsync(() async {
        es.reconnectCurrent();
        await flush();
      });
      // A manual try has no 停止 of its own: the record is marked as an automatic one was.
      es.currentRecord!.retry = (0, DateTime.now());
      es.stopReconnectCurrent();
      await tester.runAsync(() async {
        t.emit({'event': 'error', 'req': req, 'error': 'cannot reach the host'});
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      expect(es.currentRecord!.reason, 'user');
      expect(find.byType(DisconnectedStage), findsOneWidget);
      expect(find.byKey(const Key('offline-bar')), findsNothing);
    });

    testWidgets('a frozen record stays frozen while it reconnects, and thaws on the swap', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5011, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.reconnectCurrent();
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      expect(es.currentRecord!.frozen, true);
      expect(es.sendBlocked(1), true);
      expect(es.sendBlocked(11), false);
      port.emit(const ReadyEvent(11, 'Safari'));
      port.emit(WindowsEvent(11, [rw(5, 400, 328)]));
      await tester.pump();
      expect(es.currentRecord!.frozen, false);
      expect(es.currentRecord!.lastSid, isNull);
      expect(es.sendBlocked(11), false);
    });

    testWidgets('a reconnect that fails for a non-network reason thaws', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({'event': 'error', 'req': m['req'], 'error': 'bad password'});
          }
        };
        es.reconnectCurrent();
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      expect(es.currentRecord!.frozen, false);
      expect(es.currentRecord!.phase, Phase.disconnected);
    });

    testWidgets('a first open that fails for a network reason, then reconnects, is not frozen', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'cannot reach the host'});
        };
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      expect(es.currentRecord!.phase, Phase.disconnected);
      expect(es.currentRecord!.frozen, false);
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5011, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.reconnectCurrent();
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      port.emit(const ReadyEvent(11, 'Safari'));
      port.emit(WindowsEvent(11, [rw(5, 400, 328)]));
      await tester.pump();
      await tester.pump();
      expect(es.currentRecord!.phase, Phase.live);
      expect(es.currentRecord!.frozen, false);
      expect(es.sendBlocked(11), false);
      expect(find.byKey(const Key('offline-bar')), findsNothing);
      expect(tester.widget<Picture>(find.byType(Picture)).frozen, false);
      es.currentRemote!.composer.open = true;
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('composer-field')), 'ls');
      await tester.pump();
      expect(tester.widget<RappButton>(find.byKey(const Key('composer-send'))).onPressed, isNotNull);
    });

    testWidgets('the old sid closing mid-reconnect leaves no frozen flag behind', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      await tester.pump();
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5011, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.reconnectCurrent();
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      port.emit(const ClosedEvent(1, 'connection closed'));
      await tester.pump();
      expect(es.currentRecord!.lastSid, isNull);
      expect(es.currentRecord!.frozen, false);
      expect(es.sendBlocked(11), false);
    });

    testWidgets('reconnect is off when the hub is gone', (tester) async {
      await shown(tester);
      port.emit(const DisconnectedEvent(1, 'user'));
      await tester.pump();
      await tester.runAsync(() async {
        await t.die();
        await flush();
      });
      await tester.pump();
      // The hub's problem takes the stage; with it gone there is nothing to reconnect to.
      expect(find.byKey(const Key('reconnect-button')), findsNothing);
      expect(es.hubUsable, false);
    });

    testWidgets('reconnect button is greyed without a callback', (tester) async {
      await tester.pumpWidget(wrap(const SizedBox(
          width: 400, height: 300, child: DisconnectedStage(session: null, reason: '网络断了', connecting: false))));
      expect(tester.widget<RappButton>(find.byKey(const Key('reconnect-button'))).onPressed, isNull);
      expect(find.byType(Texture), findsNothing);
    });

    testWidgets('the reconnect controls sit in the composer\'s see-through box', (tester) async {
      await tester.pumpWidget(wrap(const SizedBox(
          width: 400, height: 300, child: DisconnectedStage(session: null, reason: '网络断了', connecting: false))));
      final box = find.byKey(const Key('disconnected-box'));
      expect(find.descendant(of: box, matching: find.byKey(const Key('reconnect-button'))), findsOneWidget);
      expect(find.descendant(of: box, matching: find.byKey(const Key('disconnect-reason'))), findsOneWidget);
      final d = tester.widget<Container>(box).decoration! as BoxDecoration;
      final t = RappTokens.of(tester.element(box));
      expect(d, seeThroughBox(t));
      final fills = [?d.color, ...?d.gradient?.colors];
      expect(fills, isNotEmpty);
      for (final c in fills) {
        expect(c.a, closeTo(composerFillOpacity, 0.01), reason: 'as see-through as the composer');
      }
    });

    testWidgets('a retrying stage says so and offers 停止 instead of 重连', (tester) async {
      var stopped = false;
      await tester.pumpWidget(wrap(SizedBox(
          width: 400,
          height: 300,
          child: DisconnectedStage(
              session: null, reason: '网络断了', connecting: false, retrying: true, onStop: () => stopped = true))));
      expect(find.text('正在重连…'), findsOneWidget);
      expect(find.byKey(const Key('reconnect-button')), findsNothing);
      await tester.tap(find.byKey(const Key('stop-reconnect-button')));
      expect(stopped, true);
    });

    testWidgets('a waiting stage says what it waits for instead of the reason and 正在重连…', (tester) async {
      var stopped = false;
      await tester.pumpWidget(wrap(SizedBox(
          width: 400,
          height: 300,
          child: DisconnectedStage(
              session: null,
              reason: '对方离线',
              waiting: '对方离线，上线后自动连',
              connecting: false,
              retrying: true,
              onStop: () => stopped = true))));
      expect(find.text('对方离线，上线后自动连'), findsOneWidget);
      expect(find.text('对方离线'), findsNothing);
      expect(find.text('正在重连…'), findsNothing);
      await tester.tap(find.byKey(const Key('stop-reconnect-button')));
      expect(stopped, true);
    });

    testWidgets('a retrying stage keeps 停止 while an attempt is in flight', (tester) async {
      var stopped = false;
      await tester.pumpWidget(wrap(SizedBox(
          width: 400,
          height: 300,
          child: DisconnectedStage(
              session: null, reason: '网络断了', connecting: true, retrying: true, onStop: () => stopped = true))));
      expect(find.text('正在重连…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('stop-reconnect-button')));
      expect(stopped, true);
    });

    testWidgets('a detached session that disconnects has no window to switch to', (tester) async {
      await shown(tester);
      port.emit(const DetachedEvent(1, true));
      await tester.pump();
      expect(find.text('切到窗口'), findsOneWidget);
      port.emit(const DisconnectedEvent(1, 'user'));
      port.emit(const DetachedEvent(1, false));
      await tester.pump();
      expect(find.text('切到窗口'), findsNothing);
      expect(find.byKey(const Key('reconnect-button')), findsOneWidget);
    });

    Future<void> showWindow(WidgetTester tester, RemoteWindow w) async {
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [w]));
      await tester.pump();
      await tester.pump();
    }

    List<Map<String, Object?>> mouse() => port.calls.where((c) => c.$1 == 'mouse').map((c) => c.$2).toList();
    final border = find.byKey(const Key('picture-focus'));

    testWidgets('the picture holds the keys without a tap; a press on the top bar gives them back', (tester) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(MainWindow(
        state: es,
        monitor: ServiceMonitor(readToken: () async => null),
        control: null,
        fullscreen: _NoFullscreen(),
      )));
      final size = tester.getSize(find.byKey(const Key('stage')));
      await showWindow(tester, rw(7, size.width, size.height + 28));
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'picture_focus').map((c) => c.$2), contains(equals({'sid': 1, 'compose': true})));
      expect(es.pictureFocused, 1);
      expect(border, findsOneWidget);
      port.calls.clear();
      final topBarPoint = tester.getCenter(find.byType(TopBar));
      await tester.tapAt(topBarPoint);
      await tester.pump();
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'picture_focus').map((c) => c.$2),
          [equals({'sid': null}), equals({'sid': 1, 'compose': true})]);
      expect(es.pictureFocused, 1);
      expect(border, findsOneWidget);
    });

    testWidgets('Tab and the arrows the picture lets through never walk the focus onto the top bar', (tester) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(MainWindow(
        state: es,
        monitor: ServiceMonitor(readToken: () async => null),
        control: null,
        fullscreen: _NoFullscreen(),
      )));
      final size = tester.getSize(find.byKey(const Key('stage')));
      await showWindow(tester, rw(7, size.width, size.height + 28));
      await tester.pump();
      final picture = FocusManager.instance.primaryFocus;
      expect(picture?.context?.findAncestorWidgetOfExactType<Picture>(), isNotNull);
      final seen = <FocusNode?>[];
      void log() => seen.add(FocusManager.instance.primaryFocus);
      FocusManager.instance.addListener(log);
      addTearDown(() => FocusManager.instance.removeListener(log));
      for (final k in [
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await tester.sendKeyEvent(k);
        await tester.pump();
        await tester.pump();
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      // Not even for a frame: a highlight that comes and goes is the flashing.
      expect(seen.where((f) => f != picture), isEmpty);
      expect(FocusManager.instance.primaryFocus, picture);
    });

    testWidgets('a session that stops being current loses picture focus', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      await tester.tapAt(tester.getCenter(find.byType(Texture)));
      await tester.pump();
      expect(es.pictureFocused, 1);
      port.calls.clear();
      es.select('111/Other');
      await tester.pump();
      expect(es.pictureFocused, isNull);
      expect(port.calls.where((c) => c.$1 == 'picture_focus').single.$2, equals({'sid': null}));
    });

    testWidgets('down outside the picture is not sent; drag is clamped', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      // Content 400x200 on an 800x600 stage: fit is (0,100) 800x400, bands above and below.
      await showWindow(tester, rw(7, 400, 228));
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      await tester.tapAt(o + const Offset(400, 50));
      await tester.pump();
      expect(mouse(), isEmpty);
      final g = await tester.startGesture(o + const Offset(400, 300), kind: PointerDeviceKind.mouse);
      await g.moveTo(o + const Offset(850, 300));
      await g.up();
      await tester.pump();
      final m = mouse();
      expect(m.map((c) => c['kind']), ['down', 'drag', 'up']);
      expect(m[1]['x'], 400.0);
      expect(m[1]['y'], 28 + 100.0);
      expect(m[2]['x'], 400.0);
    });

    testWidgets('a press in the letterbox sends nothing, and the keys come back to the picture', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 228)); // fit (0,100) 800x400
      await tester.pump();
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      expect(es.pictureFocused, 1);
      port.calls.clear();
      await tester.tapAt(o + const Offset(400, 50));
      await tester.pump();
      await tester.pump();
      expect(port.calls.map((c) => c.$1), ['picture_focus', 'picture_focus']);
      expect(port.calls.first.$2, equals({'sid': null}));
      expect(es.pictureFocused, 1);
      expect(border, findsOneWidget);
    });

    testWidgets('a new current session\'s picture takes the keys without a tap', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      await tester.pump();
      expect(es.pictureFocused, 1);
      expect(border, findsOneWidget);
    });

    testWidgets('a picture with no area sends nothing', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 0, 28));
      await tester.tapAt(tester.getCenter(find.byKey(const Key('stage'))));
      await tester.pump();
      expect(mouse(), isEmpty);
    });

    testWidgets('right button sends right', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      final g = await tester.startGesture(tester.getCenter(find.byType(Texture)),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await g.up();
      await tester.pump();
      expect(mouse().map((c) => (c['kind'], c['button'])), [('down', 'right'), ('up', 'right')]);
    });

    testWidgets('mouse down sends A points and click count', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      // Content 400x300 on 800x600: twice as big, no bands.
      await showWindow(tester, rw(7, 400, 328));
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(o + const Offset(200, 100), timeStamp: Duration.zero);
      await g.up(timeStamp: const Duration(milliseconds: 50));
      await g.down(o + const Offset(201, 100), timeStamp: const Duration(milliseconds: 200));
      await g.up(timeStamp: const Duration(milliseconds: 250));
      await g.down(o + const Offset(201, 100), timeStamp: const Duration(seconds: 2));
      await g.up(timeStamp: const Duration(milliseconds: 2050));
      await tester.pump();
      final downs = mouse().where((c) => c['kind'] == 'down').toList();
      expect(downs[0], equals({'sid': 1, 'kind': 'down', 'button': 'left', 'window': 7, 'x': 100.0, 'y': 78.0, 'clicks': 1}));
      expect(downs.map((c) => c['clicks']), [1, 2, 1]);
      expect(mouse().where((c) => c['kind'] == 'up').map((c) => c['clicks']), [1, 2, 1]);
    });

    testWidgets('wheel and trackpad scroll reach A', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      await tester.sendEventToBinding(PointerScrollEvent(position: o + const Offset(200, 100), scrollDelta: const Offset(0, 40)));
      final pad = TestPointer(9, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.panZoomStart(o + const Offset(200, 100)));
      await tester.sendEventToBinding(pad.panZoomUpdate(o + const Offset(200, 100), pan: const Offset(0, 12)));
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();
      final s = port.calls.where((c) => c.$1 == 'scroll').map((c) => c.$2).toList();
      expect(s.length, 2);
      expect(s[0], equals({'sid': 1, 'window': 7, 'x': 100.0, 'y': 78.0, 'dx': 0.0, 'dy': -5.0})); // drawn twice as big: A's points are half B's
      expect(s[1]['dy'], 6.0);
      expect(mouse(), isEmpty);
    });

    testWidgets('switching sessions raises A before the first trackpad scroll', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      expect(port.calls.where((c) => c.$1 == 'select_window').map((c) => c.$2),
          [{'sid': 1, 'window': 7}]);
      await tester.runAsync(() async {
        t.emit({'event': 'opened', 'sid': 2, 'id': '111', 'app': 'Notes', 'path': 'lan',
          'port': 5002, 'token': 'tk'});
        for (var i = 0; i < 4; i++) { await flush(); }
      });
      port.emit(const ReadyEvent(2, 'Notes'));
      port.emit(WindowsEvent(2, [rw(8, 400, 328)]));
      await tester.pump();
      es.select('111/Notes');
      await tester.pump();
      port.calls.clear();

      es.select('111/Safari');
      // Activation is sent at selection, without waiting for a click or layout.
      expect(port.calls.where((c) => c.$1 == 'select_window').single.$2,
          {'sid': 1, 'window': 7});
      await tester.pump();
      final at = tester.getTopLeft(find.byKey(const Key('stage'))) + const Offset(200, 100);
      final pad = TestPointer(9, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.panZoomStart(at));
      await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: const Offset(0, 12)));
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();
      final input = port.calls.where((c) => c.$1 == 'select_window' || c.$1 == 'scroll').toList();
      expect(input.map((c) => c.$1), ['select_window', 'scroll']);
      expect(input.every((c) => c.$2['sid'] == 1 && c.$2['window'] == 7), isTrue);
      expect(mouse(), isEmpty);
    });

    testWidgets('stage activation is not repeated by frames and resumes after overview', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      port.calls.clear();
      port.emit(WindowsEvent(1, [rw(7, 400, 328)]));
      await tester.pump();
      es.notifyListeners();
      expect(port.calls.where((c) => c.$1 == 'select_window'), isEmpty);
      es.toggleOverview();
      es.notifyListeners();
      expect(port.calls.where((c) => c.$1 == 'select_window'), isEmpty);
      es.toggleOverview();
      expect(port.calls.where((c) => c.$1 == 'select_window').single.$2,
          {'sid': 1, 'window': 7});
      port.calls.clear();
      port.emit(const DetachedEvent(1, true));
      await tester.pump();
      es.select('111/Safari');
      expect(port.calls.where((c) => c.$1 == 'select_window'), isEmpty);
      port.emit(const DetachedEvent(1, false));
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'select_window').single.$2,
          {'sid': 1, 'window': 7});
      port.calls.clear();
      port.emit(const DisconnectedEvent(1, 'offline'));
      await tester.pump();
      es.select('111/Safari');
      expect(port.calls.where((c) => c.$1 == 'select_window'), isEmpty);
    });

    testWidgets('a held press is released on its own session when the stage switches session', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(o + const Offset(200, 100));
      await g.moveBy(const Offset(20, 0));
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 2, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5002, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.openOrSwitch('111', 'Notes', 'Notes');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      port.emit(const ReadyEvent(2, 'Notes'));
      port.emit(WindowsEvent(2, [rw(7, 400, 328)]));
      await tester.pump();
      await tester.pump();
      final ups = mouse().where((c) => c['kind'] == 'up').toList();
      expect(ups.map((c) => (c['sid'], c['window'], c['button'])), [(1, 7, 'left')]);
      expect(ups.single['x'] as double, closeTo(110, 1e-9)); // where the drag was last sent
      expect(ups.single['y'] as double, closeTo(78, 1e-9));
      await g.up();
      await tester.pump();
      expect(mouse().where((c) => c['sid'] == 2), isEmpty);
    });

    testWidgets('a held press is released when the picture goes away', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindow(tester, rw(7, 400, 328));
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(o + const Offset(200, 100));
      await tester.pumpWidget(const SizedBox());
      await g.up();
      await tester.pump();
      expect(mouse().map((c) => (c['sid'], c['kind'], c['window'])), [(1, 'down', 7), (1, 'up', 7)]);
    });

    group('touch (P3)', () {
      Future<Offset> setup(WidgetTester tester) async {
        await tester.pumpWidget(wrap(embedded()));
        await showWindow(tester, rw(7, 400, 328)); // 400x300 on 800x600: twice as big
        return tester.getTopLeft(find.byKey(const Key('stage')));
      }

      List<Map<String, Object?>> scrolls() => port.calls.where((c) => c.$1 == 'scroll').map((c) => c.$2).toList();

      testWidgets('a two-finger swipe scrolls A at the fingers\' centre and never clicks', (tester) async {
        final o = await setup(tester);
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        await f1.down(o + const Offset(200, 100));
        await f2.down(o + const Offset(240, 100));
        // both fingers move in one event batch (one frame): one scroll with the centre's full move
        final b = tester.binding;
        b.handlePointerEvent(PointerMoveEvent(pointer: 11, kind: PointerDeviceKind.touch, position: o + const Offset(200, 80)));
        b.handlePointerEvent(PointerMoveEvent(pointer: 12, kind: PointerDeviceKind.touch, position: o + const Offset(240, 80)));
        await tester.pump();
        await f1.up();
        await f2.up();
        await tester.pump(const Duration(milliseconds: 300));
        final s = scrolls();
        expect(s.length, 1);
        // the centre moved 20 B points = 10 A points (the picture is drawn twice as big)
        expect(s[0], allOf(containsPair('sid', 1), containsPair('window', 7), containsPair('dx', 0.0), containsPair('dy', -10.0)));
        expect(s[0]['x'] as double, closeTo(110, 1e-9));
        expect(s[0]['y'] as double, closeTo(68, 1e-9));
        expect(mouse(), isEmpty);
      });

      testWidgets('two-finger tap is a right click at the midpoint', (tester) async {
        final o = await setup(tester);
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        await f1.down(o + const Offset(100, 100), timeStamp: Duration.zero);
        await f2.down(o + const Offset(140, 100), timeStamp: const Duration(milliseconds: 10));
        await f1.up(timeStamp: const Duration(milliseconds: 90));
        await f2.up(timeStamp: const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 300));
        // midpoint (120,100) on a stage drawn twice as big: A's (60, 50 + 28 title bar)
        expect(mouse().map((c) => (c['kind'], c['button'], c['x'], c['y'])),
            [('down', 'right', 60.0, 78.0), ('up', 'right', 60.0, 78.0)]);
        expect(scrolls(), isEmpty);
      });

      testWidgets('two-finger move past 8px scrolls, no right click', (tester) async {
        final o = await setup(tester);
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        await f1.down(o + const Offset(100, 100), timeStamp: Duration.zero);
        await f2.down(o + const Offset(140, 100), timeStamp: Duration.zero);
        final b = tester.binding;
        // both fingers 6 px up: the centre moved 6 px, still held back
        b.handlePointerEvent(PointerMoveEvent(pointer: 11, kind: PointerDeviceKind.touch, position: o + const Offset(100, 94)));
        b.handlePointerEvent(PointerMoveEvent(pointer: 12, kind: PointerDeviceKind.touch, position: o + const Offset(140, 94)));
        await tester.pump();
        expect(scrolls(), isEmpty);
        // 20 px in all: the 6 held back go out with the rest
        b.handlePointerEvent(PointerMoveEvent(pointer: 11, kind: PointerDeviceKind.touch, position: o + const Offset(100, 80)));
        b.handlePointerEvent(PointerMoveEvent(pointer: 12, kind: PointerDeviceKind.touch, position: o + const Offset(140, 80)));
        await tester.pump();
        await f1.up(timeStamp: const Duration(milliseconds: 50));
        await f2.up(timeStamp: const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 300));
        expect(scrolls().length, 1);
        expect(scrolls()[0]['dy'], -10.0); // all 20 px of the centre, half in A's points
        expect(mouse(), isEmpty);
      });

      testWidgets('two-finger hold over 250ms is not a right click', (tester) async {
        final o = await setup(tester);
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        await f1.down(o + const Offset(100, 100), timeStamp: Duration.zero);
        await f2.down(o + const Offset(140, 100), timeStamp: Duration.zero);
        await f1.up(timeStamp: const Duration(milliseconds: 300));
        await f2.up(timeStamp: const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(mouse(), isEmpty);
        expect(scrolls(), isEmpty);
      });

      testWidgets('trackpad pan-zoom scrolls', (tester) async {
        final o = await setup(tester);
        final pad = TestPointer(9, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(pad.panZoomStart(o + const Offset(200, 100)));
        await tester.sendEventToBinding(pad.panZoomUpdate(o + const Offset(200, 100), pan: const Offset(0, 12)));
        await tester.sendEventToBinding(pad.panZoomEnd());
        await tester.pump();
        expect(scrolls().length, 1);
        expect(scrolls()[0]['dy'], 6.0);
        expect(mouse(), isEmpty);
      });

      testWidgets('a one-finger tap clicks where it landed', (tester) async {
        final o = await setup(tester);
        await tester.tapAt(o + const Offset(200, 100));
        await tester.pump();
        final m = mouse();
        expect(m.map((c) => c['kind']), ['down', 'up']);
        expect(m[0], equals({'sid': 1, 'kind': 'down', 'button': 'left', 'window': 7, 'x': 100.0, 'y': 78.0, 'clicks': 1}));
      });

      testWidgets('a one-finger drag presses where it landed once it moves past 8 px', (tester) async {
        final o = await setup(tester);
        final g = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        await g.down(o + const Offset(200, 100));
        await g.moveBy(const Offset(5, 0));
        expect(mouse(), isEmpty);
        await g.moveBy(const Offset(10, 0));
        await g.up();
        await tester.pump();
        final m = mouse();
        expect(m.map((c) => c['kind']), ['down', 'drag', 'up']);
        expect(m[0]['x'], 100.0);
        expect(m[1]['x'], 107.5);
        expect(scrolls(), isEmpty);
      });

      testWidgets('a finger held 150 ms presses; a second finger then neither scrolls nor drags', (tester) async {
        final o = await setup(tester);
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        await f1.down(o + const Offset(200, 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(mouse(), isEmpty);
        await tester.pump(const Duration(milliseconds: 100));
        expect(mouse().map((c) => c['kind']), ['down']);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        await f2.down(o + const Offset(240, 100));
        await f2.moveBy(const Offset(0, -20));
        await f2.up();
        await f1.up();
        await tester.pump();
        expect(scrolls(), isEmpty);
        expect(mouse().map((c) => c['kind']), ['down', 'up']);
      });

      testWidgets('lifting one finger mid-scroll keeps scrolling and never clicks', (tester) async {
        final o = await setup(tester);
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        await f1.down(o + const Offset(200, 100));
        await f2.down(o + const Offset(240, 100));
        await f1.up();
        await f2.moveBy(const Offset(0, -20));
        await f2.up();
        await tester.pump(const Duration(milliseconds: 300));
        expect(scrolls().length, 1);
        expect(mouse(), isEmpty);
      });

      testWidgets('a cancelled touch sends nothing', (tester) async {
        final o = await setup(tester);
        final g = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        await g.down(o + const Offset(200, 100));
        await g.cancel();
        await tester.pump(const Duration(milliseconds: 300));
        expect(mouse(), isEmpty);
      });

      testWidgets('a swipe whose first finger lands in the letterbox still scrolls (review I1)', (tester) async {
        await tester.pumpWidget(wrap(embedded()));
        await showWindow(tester, rw(7, 400, 228)); // fit (0,100) 800x400: letterbox above y=100
        final o = tester.getTopLeft(find.byKey(const Key('stage')));
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        await f1.down(o + const Offset(200, 95));
        await f2.down(o + const Offset(240, 110));
        await f1.moveBy(const Offset(0, 20));
        await f2.moveBy(const Offset(0, 20));
        await f1.up();
        await f2.up();
        await tester.pump(const Duration(milliseconds: 300));
        expect(scrolls(), isNotEmpty);
        expect(mouse(), isEmpty);
      });

      testWidgets('a held-back press is dropped when the window changes (review I2)', (tester) async {
        final o = await setup(tester);
        final g = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        await g.down(o + const Offset(200, 100));
        port.emit(WindowsEvent(1, [rw(8, 400, 328)]));
        await tester.pump(); // the picture now shows window 8; the press is still held back
        await tester.pump(const Duration(milliseconds: 200));
        await g.up();
        await tester.pump();
        expect(mouse(), isEmpty);
      });

      testWidgets('a held-back press is dropped when the picture goes away (review M1)', (tester) async {
        final o = await setup(tester);
        final g = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        await g.down(o + const Offset(200, 100));
        await tester.pumpWidget(const SizedBox());
        await g.up();
        await tester.pump();
        expect(mouse(), isEmpty);
      });

      testWidgets('a third finger while scrolling is ignored (T5)', (tester) async {
        final o = await setup(tester);
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        final f3 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 13);
        await f1.down(o + const Offset(200, 100));
        await f2.down(o + const Offset(240, 100));
        await f3.down(o + const Offset(400, 300));
        await f3.moveBy(const Offset(0, -30));
        expect(scrolls(), isEmpty);
        await f1.moveBy(const Offset(0, -20));
        await tester.pump();
        expect(scrolls().single['dy'], -5.0); // the centre moved 10 B points = 5 A points
        expect(scrolls().single['x'] as double, closeTo(110, 1e-9));
        await f1.up();
        await f2.up();
        await f3.up();
        await tester.pump(const Duration(milliseconds: 300));
        expect(mouse(), isEmpty);
      });

      testWidgets('a tap with a little jitter releases where it landed (review M3)', (tester) async {
        final o = await setup(tester);
        final g = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        await g.down(o + const Offset(200, 100));
        await g.moveBy(const Offset(6, 0));
        await g.up();
        await tester.pump();
        expect(mouse().map((c) => (c['kind'], c['x'])), [('down', 100.0), ('up', 100.0)]);
      });

      testWidgets('a mouse press is not held back', (tester) async {
        final o = await setup(tester);
        final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await g.down(o + const Offset(200, 100));
        expect(mouse().map((c) => c['kind']), ['down']);
        await g.up();
      });
    });

    group('pinch zoom', () {
      /// [body] as on an iPad; the override never outlives the test (Flutter asserts on a leaked one).
      Future<void> on(TargetPlatform p, Future<void> Function() body) async {
        debugDefaultTargetPlatformOverride = p;
        try {
          await body();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }

      Future<void> onIOS(Future<void> Function() body) => on(TargetPlatform.iOS, body);

      Future<Offset> setup(WidgetTester tester, {List<RemoteWindow>? windows, Widget? root}) async {
        await tester.pumpWidget(wrap(root ?? embedded()));
        await openEmbedded(tester);
        port.emit(const ReadyEvent(1, 'Safari'));
        port.emit(WindowsEvent(1, windows ?? [rw(7, 400, 328)])); // 400x300 on 800x600: twice as big
        await tester.pump();
        await tester.pump();
        return tester.getTopLeft(find.byKey(const Key('stage')));
      }

      List<Map<String, Object?>> views() => port.calls.where((c) => c.$1 == 'set_view').map((c) => c.$2).toList();
      List<Map<String, Object?>> scrolls() => port.calls.where((c) => c.$1 == 'scroll').map((c) => c.$2).toList();

      /// Two fingers [from] each side of [at] spread (or close) to [to] each side in one event batch: the zoom
      /// goes times to / from about [at]. Lifted unless [lift] is false; the fingers are returned.
      Future<(TestGesture, TestGesture)> pinch(WidgetTester tester, Offset o,
          {Offset at = const Offset(400, 300), double from = 100, double to = 200, bool lift = true}) async {
        final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 21);
        final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 22);
        await f1.down(o + at - Offset(from, 0));
        await f2.down(o + at + Offset(from, 0));
        final b = tester.binding;
        b.handlePointerEvent(PointerMoveEvent(pointer: 21, kind: PointerDeviceKind.touch, position: o + at - Offset(to, 0)));
        b.handlePointerEvent(PointerMoveEvent(pointer: 22, kind: PointerDeviceKind.touch, position: o + at + Offset(to, 0)));
        await tester.pump();
        if (lift) {
          await f1.up();
          await f2.up();
          await tester.pump();
        }
        return (f1, f2);
      }

      /// What A is told for window 7 zoomed 2x about the stage's centre: the middle 200x150 of its 400x300 content,
      /// widened by 25 % each side.
      Map<String, Object?> view7(Object sid, {int window = 7}) =>
          {'sid': sid, 'window': window, 'x': 50.0, 'y': 37.5, 'w': 300.0, 'h': 225.0, 'zoom': 2.0};
      const unlimited = {'sid': 1, 'window': 0, 'x': 0.0, 'y': 0.0, 'w': 0.0, 'h': 0.0, 'zoom': 1.0};

      testWidgets('pinch zooms and sends nothing to A', (tester) async {
        await onIOS(() async {
          final o = await setup(tester);
          await pinch(tester, o);
          expect(es.remote[1]!.zoomOf(7).z, greaterThan(1));
          expect(es.remote[1]!.zoomOf(7).z, 2.0);
          expect(port.calls.where((c) => c.$1 == 'mouse' || c.$1 == 'scroll'), isEmpty);
        });
      });

      testWidgets('zoomed tap lands where it shows', (tester) async {
        await onIOS(() async {
          final o = await setup(tester);
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          port.calls.clear();
          final win = es.remote[1]!.windows.single;
          final stage = tester.getSize(find.byKey(const Key('stage')));
          final zfit = es.remote[1]!.zoomOf(7).zfit(fitRect(contentSize(win), stage), stage);
          expect(zfit, const Rect.fromLTWH(-400, -300, 1600, 1200));
          await tester.tapAt(o + const Offset(200, 100));
          await tester.pump();
          final p = toRemote(const Offset(200, 100), zfit, win);
          expect(p, const Offset(150, 128));
          expect(mouse().map((c) => (c['kind'], c['x'], c['y'])), [('down', p.dx, p.dy), ('up', p.dx, p.dy)]);
        });
      });

      testWidgets('zoomed drag pans only', (tester) async {
        await onIOS(() async {
          final o = await setup(tester);
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          port.calls.clear();
          final g = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 31);
          await g.down(o + const Offset(300, 300));
          await g.moveBy(const Offset(20, 0));
          await g.moveBy(const Offset(30, 0));
          await g.up();
          await tester.pump();
          expect(mouse(), isEmpty);
          expect(scrolls(), isEmpty);
          final z = es.remote[1]!.zoomOf(7);
          expect(z.z, 2.0);
          expect(z.zfit(const Rect.fromLTWH(0, 0, 800, 600), const Size(800, 600)).left, -350);
        });
      });

      testWidgets('zoomed hold 500 ms then drag sends down, drag, up', (tester) async {
        await onIOS(() async {
          final o = await setup(tester);
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          port.calls.clear();
          final centre = es.remote[1]!.zoomOf(7).centre;
          final g = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 31);
          await g.down(o + const Offset(300, 300));
          await tester.pump(const Duration(milliseconds: 499));
          expect(mouse(), isEmpty);
          await tester.pump(const Duration(milliseconds: 2));
          await g.moveBy(const Offset(20, 0));
          await g.up();
          await tester.pump();
          expect(mouse().map((c) => c['kind']), ['down', 'drag', 'up']);
          expect(es.remote[1]!.zoomOf(7).centre, centre);
        });
      });

      testWidgets('zoomed two-finger move scrolls', (tester) async {
        await onIOS(() async {
          final o = await setup(tester);
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          port.calls.clear();
          final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 31);
          final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 32);
          await f1.down(o + const Offset(300, 300));
          await f2.down(o + const Offset(340, 300));
          final b = tester.binding;
          b.handlePointerEvent(PointerMoveEvent(pointer: 31, kind: PointerDeviceKind.touch, position: o + const Offset(300, 280)));
          b.handlePointerEvent(PointerMoveEvent(pointer: 32, kind: PointerDeviceKind.touch, position: o + const Offset(340, 280)));
          await tester.pump();
          await f1.up();
          await f2.up();
          await tester.pump(const Duration(milliseconds: 300));
          expect(scrolls().length, 1);
          expect(scrolls()[0]['dy'], -5.0); // 20 B points on a picture drawn four times as big
          expect(mouse(), isEmpty);
          expect(es.remote[1]!.zoomOf(7).z, 2.0);
        });
      });

      testWidgets('setView 150 ms after the fingers lift, not during', (tester) async {
        await onIOS(() async {
          final o = await setup(tester);
          final (f1, f2) = await pinch(tester, o, lift: false);
          await tester.pump(const Duration(milliseconds: 300));
          expect(views(), isEmpty);
          await f1.up();
          await f2.up();
          await tester.pump(const Duration(milliseconds: 149));
          expect(views(), isEmpty);
          await tester.pump(const Duration(milliseconds: 2));
          expect(views(), [view7(1)]);
        });
      });

      testWidgets('back to 1 sends the unlimited view', (tester) async {
        await onIOS(() async {
          final o = await setup(tester);
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), [view7(1)]);
          port.calls.clear();
          await pinch(tester, o, from: 200, to: 100);
          expect(es.remote[1]!.zoomOf(7).z, 1.0);
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), [unlimited]);
          await tester.pump(const Duration(seconds: 1)); // the backdrop's tail
        });
      });

      /// The embedded stage at [w] x [h], with the soft keyboard [keyboard] up over its bottom.
      Widget sized({double w = 800, double h = 600, double keyboard = 0}) => SizedBox(
            width: w,
            height: h,
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
                child: Backdrop(theme: RappTheme.matrix, child: Stage(state: es, composerEditor: FlutterEditor.new)),
              ),
            ),
          );

      testWidgets('zoomed, a new stage size (a rotation) tells A the view again', (tester) async {
        await onIOS(() async {
          final o = await setup(tester, root: sized());
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), [view7(1)]);
          port.calls.clear();
          await tester.pumpWidget(wrap(sized(w: 600, h: 800)));
          await tester.pump(const Duration(milliseconds: 200));
          final v = views().single;
          expect((v['window'], v['zoom']), (7, 2.0));
          expect(v['h'] as double, greaterThan(225)); // the taller stage sees more of the window's height
          await tester.pump(const Duration(seconds: 2));
          expect(views(), [v]);
        });
      });

      testWidgets('zoomed, the soft keyboard going away tells A the view again', (tester) async {
        await onIOS(() async {
          final o = await setup(tester, root: sized(keyboard: 300));
          await pinch(tester, o, at: const Offset(400, 150));
          await tester.pump(const Duration(milliseconds: 200));
          final before = views().single;
          port.calls.clear();
          await tester.pumpWidget(wrap(sized()));
          await tester.pump(const Duration(milliseconds: 200));
          final v = views().single;
          expect((v['window'], v['zoom']), (7, 2.0));
          expect(v['h'] as double, greaterThan(before['h'] as double)); // the stage under the keyboard shows now
        });
      });

      testWidgets('zoomed, A resizing the window tells A the view again', (tester) async {
        await onIOS(() async {
          final o = await setup(tester);
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), [view7(1)]);
          port.calls.clear();
          port.emit(WindowsEvent(1, [rw(7, 400, 628)])); // content 400x600
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          final v = views().single;
          expect((v['window'], v['zoom']), (7, 2.0));
          expect(v['h'] as double, greaterThan(225));
        });
      });

      testWidgets('zoomed, a stage change that stays inside the told range sends nothing', (tester) async {
        await onIOS(() async {
          final o = await setup(tester, root: sized());
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), [view7(1)]);
          port.calls.clear();
          await tester.pumpWidget(wrap(sized(w: 820)));
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), isEmpty);
        });
      });

      testWidgets('at z 1, stage, keyboard and window size changes send no view', (tester) async {
        await onIOS(() async {
          await setup(tester, root: sized());
          await tester.pump(const Duration(milliseconds: 200));
          port.calls.clear();
          await tester.pumpWidget(wrap(sized(w: 600, h: 800)));
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pumpWidget(wrap(sized(w: 600, h: 800, keyboard: 300)));
          await tester.pump(const Duration(milliseconds: 200));
          port.emit(WindowsEvent(1, [rw(7, 400, 628)]));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), isEmpty);
        });
      });

      testWidgets('switching tab sends unlimited for an unzoomed window and the view for a zoomed one', (tester) async {
        await onIOS(() async {
          final o = await setup(tester, windows: [rw(7, 400, 328), rw(8, 400, 328)]);
          expect(es.remote[1]!.currentWindow, 7);
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), [view7(1)]);
          port.calls.clear();
          es.selectWindow(8);
          await tester.pump();
          await tester.pump();
          expect(views(), [unlimited]);
          port.calls.clear();
          es.selectWindow(7);
          await tester.pump();
          await tester.pump();
          expect(views(), [view7(1)]);
        });
      });

      testWidgets('leaving the stage (overview) sends unlimited', (tester) async {
        await onIOS(() async {
          tester.view.physicalSize = const Size(1194, 834);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(wrap(MainWindow(
            state: es,
            monitor: ServiceMonitor(readToken: () async => null),
            control: null,
            fullscreen: _NoFullscreen(),
          )));
          final size = tester.getSize(find.byKey(const Key('stage')));
          await showWindow(tester, rw(7, size.width, size.height + 28));
          final o = tester.getTopLeft(find.byKey(const Key('stage')));
          await pinch(tester, o, at: Offset(size.width / 2, size.height / 2));
          await tester.pump(const Duration(milliseconds: 200));
          expect(views().single['window'], 7);
          port.calls.clear();
          es.toggleOverview();
          await tester.pump();
          await tester.pump();
          expect(views(), [unlimited]);
          port.calls.clear();
          es.toggleOverview();
          await tester.pump();
          await tester.pump();
          expect(views().single['window'], 7);
        });
      });

      testWidgets('the base texture is drawn under the live one while zoomed and 1 s after', (tester) async {
        await onIOS(() async {
          const w = RemoteWindow(
            id: 7, parent: 0, kind: WindowKind.normal, title: 'w7', rect: Rect.fromLTWH(0, 0, 400, 328),
            titleBar: 28, resizable: true, focused: true, texture: 42, baseTexture: 43,
            visible: Rect.fromLTWH(0.25, 0.25, 0.5, 0.5),
          );
          final o = await setup(tester, windows: [w]);
          List<int> textures() => tester.widgetList<Texture>(find.byType(Texture)).map((t) => t.textureId).toList();
          expect(textures(), [42]);
          await pinch(tester, o);
          expect(textures(), [43, 42]);
          await pinch(tester, o, from: 200, to: 100);
          expect(es.remote[1]!.zoomOf(7).z, 1.0);
          // Back at 1, A's live picture still covers only the old range until its whole frame comes (§6.4).
          expect(textures(), [43, 42]);
          await tester.pump(const Duration(milliseconds: 1100));
          expect(textures(), [42]);
        });
      });

      testWidgets('zoomed, a tap on the base picture outside the live part reaches A', (tester) async {
        await onIOS(() async {
          const w = RemoteWindow(
            id: 7, parent: 0, kind: WindowKind.normal, title: 'w7', rect: Rect.fromLTWH(0, 0, 400, 328),
            titleBar: 28, resizable: true, focused: true, texture: 42, baseTexture: 43,
            visible: Rect.fromLTWH(0.4, 0.4, 0.2, 0.2),
          );
          final o = await setup(tester, windows: [w]);
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          final stage = tester.getSize(find.byKey(const Key('stage')));
          final zfit = es.remote[1]!.zoomOf(7).zfit(fitRect(contentSize(w), stage), stage);
          expect(zfit, const Rect.fromLTWH(-400, -300, 1600, 1200)); // the live part: (240, 180, 320, 240)
          port.calls.clear();
          await tester.tapAt(o + const Offset(100, 100));
          await tester.pump();
          final p = toRemote(const Offset(100, 100), zfit, w);
          expect(mouse().map((c) => (c['kind'], c['x'], c['y'])), [('down', p.dx, p.dy), ('up', p.dx, p.dy)]);
          expect(port.calls.where((c) => c.$1 == 'picture_focus' && c.$2['sid'] == null), isEmpty);
        });
      });

      testWidgets('macOS: pinch never zooms', (tester) async {
        await on(TargetPlatform.macOS, () async {
          final o = await setup(tester);
          final f1 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 21);
          final f2 = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 22);
          await f1.down(o + const Offset(300, 300));
          await f2.down(o + const Offset(500, 300));
          // One finger spreads 13 px a batch: on an iPad the distance decides first (a pinch).
          for (var i = 1; i <= 8; i++) {
            tester.binding.handlePointerEvent(
                PointerMoveEvent(pointer: 22, kind: PointerDeviceKind.touch, position: o + Offset(500 + 13.0 * i, 300)));
            await tester.pump();
          }
          await f1.up();
          await f2.up();
          await tester.pump(const Duration(milliseconds: 300));
          expect(scrolls(), isNotEmpty);
          expect(es.remote[1]!.zoomOf(7).z, 1.0);
          expect(views(), isEmpty);
        });
      });

      testWidgets('a frozen reconnect at z 2 tells A the view once, for the fresh sid', (tester) async {
        await onIOS(() async {
          await shown(tester);
          final o = tester.getTopLeft(find.byKey(const Key('stage')));
          await pinch(tester, o);
          await tester.pump(const Duration(milliseconds: 200));
          expect(views(), [view7(1, window: 5)]);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          await tester.pump();
          expect(tester.widget<Picture>(find.byType(Picture)).frozen, true);
          await tester.runAsync(() async {
            t.onSend = (m) {
              if (m['cmd'] == 'open') {
                t.emit({
                  'event': 'opened', 'sid': 11, 'id': m['id'], 'app': m['app'], 'path': 'lan',
                  'port': 5011, 'token': 'tk', 'req': m['req'],
                });
              }
            };
            es.reconnectCurrent();
            for (var i = 0; i < 4; i++) {
              await flush();
            }
          });
          await tester.pump();
          port.calls.clear();
          port.emit(const ReadyEvent(11, 'Safari'));
          port.emit(WindowsEvent(11, [rw(5, 400, 328)]));
          await tester.pump();
          await tester.pump();
          expect(es.currentRecord!.lastSid, isNull);
          expect(tester.widget<Picture>(find.byType(Picture)).frozen, false);
          expect(es.remote[11]!.zoomOf(5).z, 2.0);
          expect(views(), [view7(11, window: 5)]);
        });
      });
    });

    testWidgets('overlays never resize', (tester) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final monitor = ServiceMonitor(readToken: () async => null);
      await tester.pumpWidget(wrap(MainWindow(
        state: es,
        monitor: monitor,
        control: null,
        fullscreen: _NoFullscreen(),
      )));
      await openEmbedded(tester);
      final size = tester.getSize(find.byKey(const Key('stage')));
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, size.width, size.height + 28)]));
      await tester.pump();
      port.calls.removeWhere((c) => c.$1 == 'resize');
      await tester.tap(find.byTooltip('面板')); // left panel opens...
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('面板')); // ...and closes
      // Task 10 adds Key('traffic'): tap it here too, for the stream menu.
      await tester.pump(const Duration(seconds: 1));
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    });

    RemoteWindow popup(int id, WindowKind kind, {int parent = 0, int texture = 43}) => RemoteWindow(
          id: id,
          parent: parent,
          kind: kind,
          title: '',
          rect: const Rect.fromLTWH(50, 78, 40, 20),
          titleBar: 0,
          resizable: false,
          focused: false,
          texture: texture,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    Future<void> showWindows(WidgetTester tester, List<RemoteWindow> ws) async {
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, ws));
      await tester.pump();
      await tester.pump();
    }

    // Main content 400x300 at scale 2 on the 800x600 stage: the popup lands at (100,100) 80x40.
    testWidgets('popup over a missing parent draws over the current window', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [popup(9, WindowKind.sheet, parent: 99), rw(5, 400, 328)]);
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final tex = find.byType(Texture);
      expect(tex, findsNWidgets(2));
      final pop = tester.widgetList<Texture>(tex).toList().indexWhere((x) => x.textureId == 43);
      expect(tester.getRect(tex.at(pop)), const Rect.fromLTWH(100, 100, 80, 40).shift(o));
      // Drawn after (over) the main texture.
      expect(tester.widgetList<Texture>(tex).last.textureId, 43);
      // A press on it goes to the popup's window, in its own coordinates.
      await tester.tapAt(o + const Offset(120, 120));
      await tester.pump();
      final m = mouse().first;
      expect(m['window'], 9);
      expect(m['x'], 10.0);
      expect(m['y'], 10.0);
    });

    for (final (p, min) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
      testWidgets('a popup\'s × is an IconButton at least $min square on $p', (tester) async {
        await onPlatform(p, () async {
          await tester.pumpWidget(wrap(embedded()));
          await showWindows(tester, [popup(9, WindowKind.popover, parent: 5), rw(5, 400, 328)]);
          final close = find.byKey(const ValueKey('popup-close-9'));
          expect(tester.widget(close), isA<IconButton>());
          final s = tester.getSize(close);
          expect(s.width, greaterThanOrEqualTo(min));
          expect(s.height, greaterThanOrEqualTo(min));
          expect(tester.widget<IconButton>(close).iconSize, 20);
          // A float disc behind the × so it reads over a picture, 28 across, centred in the hit area.
          final disc = find.byKey(const ValueKey('popup-close-disc-9'));
          final deco = tester.widget<DecoratedBox>(disc).decoration as BoxDecoration;
          expect(deco.shape, BoxShape.circle);
          expect(deco.color, RappTokens.of(tester.element(close)).float.first.withValues(alpha: .85));
          expect(tester.getSize(disc), const Size(28, 28));
          expect(tester.getCenter(disc), tester.getCenter(close));
        });
      });
    }

    testWidgets('right-click on a popup\'s ×: 隐藏这类窗口 closes it and hides the ones like it, with 撤销', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [popup(9, WindowKind.popover, parent: 5), rw(5, 400, 328)]);
      expect(find.byType(Texture), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('popup-close-9')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(port.calls.where((c) => c.$1 == 'key'), isEmpty); // the menu alone sends nothing
      await tester.tap(find.text('隐藏这类窗口'));
      await tester.pumpAndSettle();
      expect(port.calls.where((c) => c.$1 == 'key').single.$2['keyCode'], escKeyCode);
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byKey(const ValueKey('popup-close-9')), findsNothing);
      expect(es.profiles.resolve('Safari').windows.first,
          const WindowRule(kind: WindowKind.popover, title: '', action: RuleAction.hide));
      expect(find.text('已隐藏这类弹出窗口，可在 app 配置里改'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(find.byType(Texture), findsNWidgets(2));
    });

    testWidgets('a long press on a popup\'s × offers 隐藏这类窗口 too (touch)', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [popup(9, WindowKind.sheet, parent: 5), rw(5, 400, 328)]);
      await tester.longPress(find.byKey(const ValueKey('popup-close-9')));
      await tester.pumpAndSettle();
      expect(find.text('隐藏这类窗口'), findsOneWidget);
      expect(port.calls.where((c) => c.$1 == 'key'), isEmpty);
    });

    testWidgets('a popup of another window is not drawn', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [rw(5, 400, 328), rw(6, 400, 328), popup(9, WindowKind.sheet, parent: 6)]);
      expect(find.byType(Texture), findsOneWidget);
    });

    testWidgets('hover over a menu popup sends move, over a normal window not', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [popup(9, WindowKind.menu, parent: 5), rw(5, 400, 328)]);
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final mouseGesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouseGesture.addPointer(location: o + const Offset(500, 500));
      await tester.pump();
      expect(mouse(), isEmpty);
      await mouseGesture.moveTo(o + const Offset(120, 120));
      await tester.pump();
      expect(mouse().single['kind'], 'move');
      expect(mouse().single['window'], 9);
      expect(mouse().single['x'], 10.0);
    });

    testWidgets('hover over a popover (address-bar list) sends move', (tester) async {
      await tester.pumpWidget(wrap(embedded()));
      await showWindows(tester, [popup(9, WindowKind.popover, parent: 5), rw(5, 400, 328)]);
      final o = tester.getTopLeft(find.byKey(const Key('stage')));
      final mouseGesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouseGesture.addPointer(location: o + const Offset(500, 500));
      await tester.pump();
      await mouseGesture.moveTo(o + const Offset(120, 120));
      await tester.pump();
      expect(mouse().single['kind'], 'move');
      expect(mouse().single['window'], 9);
    });
  });
}

class _NoFullscreen implements FullscreenControl {
  @override
  Stream<bool> get changes => const Stream.empty();
  @override
  Future<bool> isFullScreen() async => false;
  @override
  Future<void> setFullScreen(bool on) async {}
}
