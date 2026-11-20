import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_choice.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/unlock.dart';
import 'package:rapp/ui/window_menu.dart';
import '../fakes.dart';
import 'helpers.dart';

class DesktopPort extends FakeSessionPort {
  DesktopPort(this.detachSupported);
  final bool detachSupported;
  @override
  bool get supportsDetach => detachSupported;
}

class DesktopEnv {
  DesktopEnv({bool detach = true, UnlockStore? unlockStore}) {
    port = DesktopPort(detach);
    transport.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        transport.emit({'event': 'hosts', 'req': m['req'], 'hosts': []});
      } else if (m['cmd'] == 'apps' && !holdApps) {
        replyApps(m);
      } else if (m['cmd'] == 'open') {
        transport.emit({
          'event': 'opened',
          'req': m['req'],
          'sid': ++nextSid,
          'id': m['id'],
          'app': m['app'],
          'path': 'lan',
          'port': 5000,
          'token': 'tk',
        });
      }
    };
    hub = HubClient(transport);
    state = MainState(
      hub: hub,
      data: DataDir(tmp.path),
      prefs: UiPrefs(),
      port: port,
      unlockStore: unlockStore ?? UnlockStore(supported: false, memory: false),
    );
  }
  final tmp = Directory.systemTemp.createTempSync('desktop_test');
  final transport = FakeTransport();
  late final HubClient hub;
  late final DesktopPort port;
  late final MainState state;
  var nextSid = 0;
  var holdApps = false;
  List<String> displays = ['1', '22'];
  void replyApps(Map<String, dynamic> m) => transport.emit({
    'event': 'apps',
    'req': m['req'],
    'id': m['id'],
    'path': 'lan',
    'apps': [
      {
        'app': 'desktop:',
        'name': '桌面',
        'displays': [
          for (final id in displays)
            {
              'id': id,
              'name': id,
              'main': id == '1',
              'width': 1920,
              'height': 1080,
            },
        ],
      },
    ],
  });
  void open() => state.openOrSwitch('111', 'desktop:', '桌面');
  void screen(FakeAsync a, String id) {
    state.openScreen('111', id);
    a.flushMicrotasks();
  }
  Object sid(String app) => state.recordFor('111/$app')!.sid!;
  Iterable<Map<String, Object?>> calls(String method) =>
      port.calls.where((c) => c.$1 == method).map((c) => c.$2);
  void dispose() {
    state.dispose();
    hub.dispose();
    tmp.deleteSync(recursive: true);
  }
}

void main() {
  void env(void Function(FakeAsync, DesktopEnv) body, {bool detach = true}) {
    fakeAsync((a) {
      final e = DesktopEnv(detach: detach);
      try {
        e.open();
        a.flushMicrotasks();
        body(a, e);
      } finally {
        e.dispose();
        a.flushMicrotasks();
      }
    });
  }

  test('secondary screens are not opened by themselves, only picked, and never detached', () {
    env((a, e) {
      expect(e.calls('start'), hasLength(1));
      expect(e.state.entries.single.appName, '桌面（2 块屏）');
      expect(e.state.currentScreens, hasLength(2));
      expect(e.state.currentScreenIndex, 0);
      e.open();
      a.flushMicrotasks();
      expect(e.calls('start'), hasLength(1));
      e.screen(a, '22');
      expect(e.calls('start'), hasLength(2));
      expect(e.state.currentKey, '111/desktop:22');
      expect(e.state.currentScreenIndex, 1);
      expect(e.state.entries, hasLength(1));
      final windows = [
        RemoteWindow(
          id: 1,
          parent: 0,
          kind: WindowKind.normal,
          title: '屏幕 2',
          rect: const Rect.fromLTWH(0, 0, 1920, 1080),
          titleBar: 0,
          resizable: false,
          focused: true,
          texture: 1,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        ),
      ];
      e.port.emit(WindowsEvent(e.sid('desktop:22'), windows));
      expect(e.calls('detach'), isEmpty);
      // Back to the main screen: the other one stays open off the stage, so a switch back is instant.
      e.screen(a, '1');
      expect(e.state.currentKey, '111/desktop:');
      e.screen(a, '22');
      expect(e.calls('start'), hasLength(2));
    });
  });

  test(
    'closing a child is quiet, reopening restores it, main end cascades',
    () {
      env((a, e) {
        e.screen(a, '22');
        final hint = e.state.hint;
        e.port.emit(ClosedEvent(e.sid('desktop:22'), 'quit'));
        expect(e.state.hint, hint);
        expect(e.state.currentKey, '111/desktop:');
        e.screen(a, '22');
        final child = e.sid('desktop:22');
        e.screen(a, '1');
        e.state.endCurrent();
        expect(
          e.calls('close').map((c) => c['sid']),
          containsAll([e.sid('desktop:'), child]),
        );
        e.port.emit(ClosedEvent(child, 'quit'));
        expect(e.state.hint, '正在结束 桌面');
      });
    },
  );

  test('desktop screens share stream choices, including screens opened later', () {
    env((a, e) {
      final main = e.sid('desktop:');
      e.screen(a, '22');
      final child = e.sid('desktop:22');
      e.port.emit(DetachedEvent(child, true));
      e.state.remote[main]!.setChoice(const StreamChoice('duogray', 'original', 30), manual: true);
      expect(e.state.remote[child]!.choice, e.state.remote[main]!.choice);
      expect(e.state.remote[child]!.streamPinned, true);
      final update = e.calls('set_stream').lastWhere((c) => c['sid'] == child);
      expect(update['fps'], 30);
      expect(update['pinned'], true);
      e.port.emit(ClosedEvent(child, 'quit'));
      e.screen(a, '22');
      final fresh = e.sid('desktop:22');
      expect(e.state.remote[fresh]!.choice, e.state.remote[main]!.choice);
      expect(e.state.remote[fresh]!.streamPinned, true);
    });
  });

  test('a desktop session on smart is neither pinned nor asked for focus', () {
    env((a, e) {
      final main = e.sid('desktop:');
      e.state.remote[main]!.setChoice(const StreamChoice('duogray', 'original', 30), manual: true);
      expect(e.calls('set_stream').lastWhere((c) => c['sid'] == main)['pinned'], true);
      e.state.remote[main]!.setChoice(presetSmart, manual: true);
      final m = e.calls('set_stream').lastWhere((c) => c['sid'] == main);
      expect(m['pinned'], isNot(true));
      expect(m.containsKey('focus'), false);
    });
  });

  test('disconnected secondary is removed without retries or hints', () {
    env((a, e) {
      e.screen(a, '22');
      final hint = e.state.hint;
      e.port.emit(DisconnectedEvent(e.sid('desktop:22'), 'connection closed'));
      expect(e.state.recordFor('111/desktop:22'), isNull);
      expect(e.state.hint, hint);
      a.elapse(const Duration(seconds: 29));
      expect(e.calls('start'), hasLength(2));
    });
  });

  test(
    'poll removes vanished screens quietly and hints for additions once',
    () {
      env((a, e) {
        e.screen(a, '22');
        final child = e.sid('desktop:22');
        final hint = e.state.hint;
        e.displays = ['1'];
        a.elapse(const Duration(seconds: 30));
        a.flushMicrotasks();
        expect(e.calls('close').last['sid'], child);
        e.port.emit(ClosedEvent(child, 'quit'));
        expect(e.state.hint, hint);
        expect(e.state.currentKey, '111/desktop:');
        expect(e.state.currentScreens, isEmpty);
        e.displays = ['1', '333'];
        a.elapse(const Duration(seconds: 30));
        a.flushMicrotasks();
        expect(e.state.hint, screenAddedHint);
        expect(e.state.recordFor('111/desktop:333'), isNull);
        e.state.hint = '其他提示';
        a.elapse(const Duration(seconds: 30));
        a.flushMicrotasks();
        expect(e.state.hint, '其他提示');
        expect(e.state.currentScreens, hasLength(2));
        e.screen(a, '333');
        expect(e.state.recordFor('111/desktop:333'), isNotNull);
      });
    },
  );

  test('late display response cannot open children after main ends', () {
    env((a, e) {
      e.displays = ['1', '22', '333'];
      e.holdApps = true;
      e.open();
      a.flushMicrotasks();
      final req = e.transport.sent.lastWhere((m) => m['cmd'] == 'apps');
      e.state.endCurrent();
      e.replyApps(req);
      a.flushMicrotasks();
      expect(e.calls('start'), hasLength(1));
    });
  });

  test(
    'Linux opens screens on demand too and keeps the hidden current screen on stage',
    () {
      env((a, e) {
        expect(e.calls('start'), hasLength(1));
        expect(e.state.desktopScreens('111'), hasLength(2));
        e.state.openScreen('111', '22');
        a.flushMicrotasks();
        expect(e.state.current!.app, 'desktop:22');
        expect(e.state.entries, hasLength(1));
        e.state.openScreen('111', '1');
        a.flushMicrotasks();
        expect(e.state.current!.app, 'desktop:');
        expect(e.calls('detach'), isEmpty);
      }, detach: false);
    },
  );

  test('lock banners distinguish desktop and app and reach child windows', () {
    env((a, e) {
      final main = e.sid('desktop:');
      e.screen(a, '22');
      e.screen(a, '1');
      e.port.emit(ScreenLockedEvent(main, true));
      expect(e.state.lockBanner!.action, '输入系统密码');
      expect(e.calls('set_banner').last['text'], contains('主窗口'));
      e.port.emit(ScreenLockedEvent(main, false));
      expect(e.state.lockBanner, isNull);
      expect(e.calls('set_banner').last['text'], '');
      e.state.openOrSwitch('111', 'app', 'App');
      a.flushMicrotasks();
      e.port.emit(ScreenLockedEvent(e.sid('app'), true));
      expect(e.state.lockBanner!.text, desktopLockText);
      expect(e.state.lockBanner!.action, '输入系统密码');
    });
  });

  testWidgets('app lock banner asks for the password; the window menu picks the screen', (
    tester,
  ) async {
    final e = DesktopEnv(detach: false);

    await tester.runAsync(() => e.state.openOrSwitch('111', 'app', 'App'));
    e.port.emit(ScreenLockedEvent(e.sid('app'), true));
    await tester.pumpWidget(wrap(Stage(state: e.state)));
    expect(find.text(desktopLockText), findsOneWidget);
    await tester.tap(find.text('输入系统密码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(UnlockDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => e.state.openOrSwitch('111', 'desktop:', '桌面'));
    await tester.pump();
    await tester.pump();
    // The stage carries no row of screen buttons any more: the top bar's window menu has them.
    expect(find.text('屏幕 1'), findsNothing);
    await tester.pumpWidget(wrap(ListenableBuilder(
      listenable: e.state,
      builder: (_, _) => WindowMenu(state: e.state, term: false),
    )));
    expect(WindowMenu.shows(e.state, term: false), isTrue);
    expect(find.text('屏幕 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('window-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('屏幕 1（主屏）'), findsOneWidget);
    await tester.tap(find.text('屏幕 2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(e.state.current!.app, 'desktop:22');
    expect(tester.widget<Text>(find.byKey(const Key('window-menu-label'))).data, '屏幕 2');
    await tester.pumpWidget(wrap(Stage(state: e.state)));
    expect(find.text('打开左侧面板，选一个会话或到设备里打开 app'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.linux}));
}
