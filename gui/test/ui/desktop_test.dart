import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import '../fakes.dart';
import 'helpers.dart';

class DesktopPort extends FakeSessionPort {
  DesktopPort(this.detachSupported);
  final bool detachSupported;
  @override
  bool get supportsDetach => detachSupported;
}

class DesktopEnv {
  DesktopEnv({bool detach = true}) {
    port = DesktopPort(detach);
    transport.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        transport.emit({'event': 'hosts', 'req': m['req'], 'hosts': []});
      } else if (m['cmd'] == 'apps' && !holdApps) {
        replyApps(m);
      } else if (m['cmd'] == 'open') {
        transport.emit({
          'event': 'opened', 'req': m['req'], 'sid': ++nextSid,
          'id': m['id'], 'app': m['app'], 'path': 'lan', 'port': 5000, 'token': 'tk',
        });
      }
    };
    hub = HubClient(transport);
    state = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
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
    'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan',
    'apps': [{'app': 'desktop:', 'name': '桌面', 'displays': [
      for (final id in displays)
        {'id': id, 'name': id, 'main': id == '1', 'width': 1920, 'height': 1080},
    ]}],
  });
  void open() => state.openOrSwitch('111', 'desktop:', '桌面');
  Object sid(String app) => state.recordFor('111/$app')!.sid!;
  Iterable<Map<String, Object?>> calls(String method) => port.calls.where((c) => c.$1 == method).map((c) => c.$2);
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

  test('secondary screens detach once, stay hidden, and count in the desktop row', () {
    env((a, e) {
      expect(e.calls('start'), hasLength(2));
      expect(e.state.entries.single.appName, '桌面（2 块屏）');
      final child = e.sid('desktop:22');
      e.port.emit(WindowsEvent(child, const []));
      expect(e.calls('detach'), isEmpty);
      final windows = [RemoteWindow(id: 1, parent: 0, kind: WindowKind.normal, title: '屏幕 2',
          rect: const Rect.fromLTWH(0, 0, 1920, 1080), titleBar: 0, resizable: false,
          focused: true, texture: 1, visible: const Rect.fromLTWH(0, 0, 1, 1))];
      e.port.emit(WindowsEvent(child, windows));
      e.port.emit(WindowsEvent(child, windows));
      expect(e.calls('detach').single['sid'], child);
      expect(e.state.currentKey, '111/desktop:');
      e.open();
      a.flushMicrotasks();
      expect(e.calls('start'), hasLength(2));
    });
  });

  test('closing a child is quiet, reopening restores it, main end cascades', () {
    env((a, e) {
      final hint = e.state.hint;
      e.port.emit(ClosedEvent(e.sid('desktop:22'), 'quit'));
      expect(e.state.hint, hint);
      expect(e.state.entries.single.appName, '桌面');
      e.open();
      a.flushMicrotasks();
      final child = e.sid('desktop:22');
      e.state.endCurrent();
      expect(e.calls('close').map((c) => c['sid']), containsAll([e.sid('desktop:'), child]));
      e.port.emit(ClosedEvent(child, 'quit'));
      expect(e.state.hint, '正在结束 桌面');
    });
  });

  test('disconnected secondary is removed without retries or hints', () {
    env((a, e) {
      final hint = e.state.hint;
      e.port.emit(DisconnectedEvent(e.sid('desktop:22'), 'connection closed'));
      expect(e.state.recordFor('111/desktop:22'), isNull);
      expect(e.state.hint, hint);
      a.elapse(const Duration(seconds: 29));
      expect(e.calls('start'), hasLength(2));
    });
  });

  test('poll removes vanished screens quietly and hints for additions once', () {
    env((a, e) {
      final child = e.sid('desktop:22');
      final hint = e.state.hint;
      e.displays = ['1'];
      a.elapse(const Duration(seconds: 30));
      a.flushMicrotasks();
      expect(e.calls('close').last['sid'], child);
      e.port.emit(ClosedEvent(child, 'quit'));
      expect(e.state.hint, hint);
      e.displays = ['1', '333'];
      a.elapse(const Duration(seconds: 30));
      a.flushMicrotasks();
      expect(e.state.hint, 'A 多了一块屏，再点一次「桌面」打开它');
      expect(e.state.recordFor('111/desktop:333'), isNull);
      e.state.hint = '其他提示';
      a.elapse(const Duration(seconds: 30));
      a.flushMicrotasks();
      expect(e.state.hint, '其他提示');
      e.open();
      a.flushMicrotasks();
      expect(e.state.recordFor('111/desktop:333'), isNotNull);
    });
  });

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
      expect(e.calls('start'), hasLength(2));
    });
  });

  test('Linux opens screens on demand and keeps hidden current screen on stage', () {
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
  });

  test('lock banners distinguish desktop and app and reach child windows', () {
    env((a, e) {
      final main = e.sid('desktop:');
      e.port.emit(ScreenLockedEvent(main, true));
      expect(e.state.lockBanner!.action, '输入系统密码');
      expect(e.calls('set_banner').last['text'], contains('主窗口'));
      e.port.emit(ScreenLockedEvent(main, false));
      expect(e.state.lockBanner, isNull);
      expect(e.calls('set_banner').last['text'], '');
      e.state.openOrSwitch('111', 'app', 'App');
      a.flushMicrotasks();
      e.port.emit(ScreenLockedEvent(e.sid('app'), true));
      expect(e.state.lockBanner!.text, 'A 已锁屏，操作不会生效。');
      expect(e.state.lockBanner!.action, '打开桌面');
    });
  });

  testWidgets('app lock action opens desktop; Linux switcher selects screen', (tester) async {
    final e = DesktopEnv(detach: false);

    await tester.runAsync(() => e.state.openOrSwitch('111', 'app', 'App'));
    e.port.emit(ScreenLockedEvent(e.sid('app'), true));
    await tester.pumpWidget(wrap(Stage(state: e.state)));
    expect(find.text('A 已锁屏，操作不会生效。'), findsOneWidget);
    await tester.tap(find.text('打开桌面'));
    await tester.pump();
    await tester.pump();
    expect(find.text('屏幕 1'), findsOneWidget);
    await tester.tap(find.text('屏幕 2'));
    await tester.pump();
    expect(e.state.current!.app, 'desktop:22');
    expect(find.text('打开左侧面板，选一个会话或到设备里打开 app'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    e.dispose();
  });
}
