import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_choice.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('main_state_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
        {'id': '222', 'name': ''},
      ],
    });
    await pump();
    s = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs());
  });

  tearDown(() {
    Process.runSync('chmod', ['755', tmp.path]);
    tmp.deleteSync(recursive: true);
  });

  int opens() => t.sent.where((m) => m['cmd'] == 'open').length;

  Map<String, dynamic> opened(int sid, String id, String app) =>
      {'event': 'opened', 'sid': sid, 'id': id, 'app': app, 'path': 'lan'};

  test('openOrSwitch sends one open while pending', () async {
    s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
    s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
    expect(opens(), 1);
    expect(s.current!.lamp, Lamp.connecting);
    expect(s.currentKey, '111/com.apple.Safari');
  });

  test('opened turns the entry active and sets the hint', () async {
    t.onSend = (m) {
      if (m['cmd'] == 'open') t.emit({...opened(1, '111', 'com.apple.Safari'), 'req': m['req']});
    };
    await s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
    expect(s.current!.lamp, Lamp.active);
    expect(s.hint, '已打开 Safari @ mini');
    expect(s.sessionCount, 1);
  });

  test('opening an open session focuses instead', () async {
    t.onSend = (m) {
      if (m['cmd'] == 'open') t.emit({...opened(1, '111', 'com.apple.Safari'), 'req': m['req']});
    };
    await s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
    s.togglePanel();
    await s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
    expect(s.panel, isNull);
    expect(t.sent.last, {'cmd': 'focus', 'sid': 1});
    expect(s.hint, '已切到 Safari');
    expect(opens(), 1);
  });

  test('open failure drops the pending entry and shows the error', () async {
    t.onSend = (m) {
      if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'offline', 'req': m['req']});
    };
    await s.openOrSwitch('111', 'a', 'A');
    expect(s.sessionCount, 0);
    expect(s.current, isNull);
    expect(s.currentKey, isNull);
    expect(s.hint, contains('offline'));
  });

  test('a failed open goes back to the session that was current', () async {
    t.emit(opened(1, '111', 'com.apple.Safari'));
    await pump();
    s.select('111/com.apple.Safari');
    t.onSend = (m) {
      if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'offline'});
    };
    await s.openOrSwitch('222', 'com.apple.Notes', 'Notes');
    expect(s.currentKey, '111/com.apple.Safari');
  });

  test('closing the current session moves to the next one', () async {
    t.emit(opened(1, '111', 'a'));
    t.emit(opened(2, '111', 'b'));
    t.emit(opened(3, '111', 'c'));
    await pump();
    s.select('111/b');
    t.emit({'event': 'closed', 'sid': 2});
    await pump();
    expect(s.currentKey, '111/c');
    expect(s.hint, '已结束 b');
    t.emit({'event': 'closed', 'sid': 3});
    t.emit({'event': 'closed', 'sid': 1});
    await pump();
    expect(s.current, isNull);
  });

  test('a session ended by the user says 已结束', () async {
    t.emit(opened(1, '111', 'a'));
    await pump();
    t.emit({'event': 'closed', 'sid': 1, 'reason': 'stdin closed'});
    await pump();
    expect(s.hint, '已结束 a');
    t.emit(opened(2, '111', 'b'));
    await pump();
    t.emit({'event': 'closed', 'sid': 2, 'reason': 'quit'});
    await pump();
    expect(s.hint, '已结束 b');
  });

  test('a session that ends on its own says 意外结束 and why', () async {
    t.emit(opened(1, '111', 'a'));
    await pump();
    t.emit({'event': 'closed', 'sid': 1, 'reason': 'rapp-client: capture failed'});
    await pump();
    expect(s.hint, 'a 意外结束：capture failed');
  });

  test('hub messages in the hint are in Chinese', () async {
    t.emit({'event': 'error', 'error': 'unknown sid'});
    await pump();
    expect(s.hint, '这个会话已经结束了');
    await t.die();
    await pump();
    expect(s.hint, 'rapp-hub 已退出');
  });

  test('select closes the panel', () async {
    t.emit(opened(1, '111', 'a'));
    await pump();
    s.togglePanel();
    expect(s.panel, PanelTab.sessions);
    s.select('111/a');
    expect(s.panel, isNull);
    expect(s.currentKey, '111/a');
  });

  test('hub death disables actions', () async {
    t.emit(opened(1, '111', 'a'));
    await pump();
    s.select('111/a');
    await t.die();
    await pump();
    expect(s.hubUsable, isFalse);
    expect(s.hubProblem, 'rapp-hub 已退出 — 重启 rapp 以恢复');
    final hint = s.hint;
    final before = t.sent.length;
    await s.openOrSwitch('111', 'x', 'X');
    s.endCurrent();
    s.focusCurrent();
    await s.probe('111');
    await s.removeDevice('111');
    expect(t.sent.length, before);
    expect(s.hint, hint);
    expect(s.currentKey, isNull);
    expect(s.sessionCount, 0);
    expect(s.probes, isEmpty);
  });

  test('probe marks online/offline', () async {
    t.onSend = (m) {
      if (m['cmd'] != 'apps') return;
      if (m['id'] == '111') {
        t.emit({'event': 'apps', 'req': m['req'], 'id': '111', 'apps': [{'app': 'a', 'name': 'Aaa'}]});
      } else {
        t.emit({'event': 'error', 'req': m['req'], 'error': 'unreachable'});
      }
    };
    await s.probe('111');
    await s.probe('222');
    expect(s.probes['111']!.lamp, Lamp.active);
    expect(s.probes['111']!.word, '在线');
    expect(s.probes['222']!.lamp, Lamp.offline);
    expect(s.probes['222']!.word, '离线');
    expect(s.probes['222']!.error, isNotEmpty);
    expect(s.onlineDevices, 1);
    expect(s.appName('111', 'a'), 'Aaa');
    expect(s.appName('111', 'zzz'), 'zzz');
    expect(s.deviceName('222'), '222');
    expect(s.deviceName('999'), '999');
  });

  test('removing the selected device returns to 本机 and keeps its sessions', () async {
    t.emit(opened(1, '111', 'a'));
    await pump();
    t.onSend = (m) {
      if (m['cmd'] == 'remove_host') t.emit({'event': 'hosts', 'req': m['req'], 'hosts': []});
    };
    s.selectDevice('111');
    expect(s.deviceTab, '111');
    await s.removeDevice('111');
    expect(s.deviceTab, isNull);
    expect(s.sessionCount, 1);
  });

  test('setTheme survives an unwritable config dir', () async {
    Process.runSync('chmod', ['500', tmp.path]);
    final s2 = MainState(hub: hub, configDir: '${tmp.path}/sub/dir', prefs: UiPrefs());
    s2.setTheme(RappTheme.avatar);
    expect(s2.prefs.theme, RappTheme.avatar);
    expect(s2.hint, startsWith('偏好没有保存：'));
  });

  test('app names survive a failed re-probe', () async {
    t.onSend = (m) {
      if (m['cmd'] == 'open') t.emit({...opened(1, '111', 'com.apple.Safari'), 'req': m['req']});
      if (m['cmd'] == 'apps') t.emit({'event': 'error', 'req': m['req'], 'error': 'x'});
    };
    await s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
    await s.probe('111');
    expect(s.current!.appName, 'Safari');
  });

  test('completing after dispose does not throw', () async {
    s.probe('111');
    final req = t.sent.last['req'];
    s.dispose();
    t.emit({'event': 'apps', 'req': req, 'id': '111', 'apps': []});
    await pump();
    await pump();
  });

  test('null hub reports its problem', () {
    final s2 = MainState(hub: null, hubError: 'boom', configDir: tmp.path, prefs: UiPrefs());
    expect(s2.hubProblem, 'boom');
    expect(s2.hubUsable, isFalse);
  });

  group('embedded sessions', () {
    void env(void Function(FakeAsync a, FakeTransport t, FakeSessionPort port, MainState st, List<String> hints) body,
        {int sessions = 1, bool withPort = true}) {
      fakeAsync((a) {
        final t = FakeTransport();
        final hub = HubClient(t);
        final port = FakeSessionPort();
        final st = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: withPort ? port : null);
        final hints = <String>[];
        var last = st.hint;
        st.addListener(() {
          if (st.hint != last) {
            last = st.hint;
            hints.add(last);
          }
        });
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            final n = (m['app'] as String).length;
            t.emit({
              'event': 'opened', 'sid': n, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              if (m['embed'] == true) ...{'port': 5000 + n, 'token': 'tk'},
              'req': m['req'],
            });
          }
        };
        a.flushMicrotasks();
        for (var i = 1; i <= sessions; i++) {
          st.openOrSwitch('111', 'a' * i, i == 1 ? 'Calculator' : 'Notes');
          a.flushMicrotasks();
        }
        hints.clear();
        body(a, t, port, st, hints);
      });
    }

    test('opening embeds: open carries embed, then start with defaults', () {
      env((a, t, port, st, hints) {
        expect(t.sent.where((m) => m['cmd'] == 'open').last['embed'], true);
        final c = port.calls.last;
        expect(c.$1, 'start');
        expect(c.$2, {'sid': 1, 'port': 5001, 'token': 'tk', 'mode': 'color16', 'fps': 15, 'density': 'adaptive'});
        expect(st.embeds, true);
        expect(st.remote.containsKey(1), true);
        expect(st.currentRemote, isNotNull);
      });
    });

    test('a stream choice on the session goes to the port as set_stream', () {
      env((a, t, port, st, hints) {
        st.currentRemote!.setChoice(const StreamChoice('duogray', 'adaptive', 1));
        expect(port.calls.last.$1, 'set_stream');
        expect(port.calls.last.$2, {'sid': 1, 'mode': 'duogray', 'fps': 1, 'density': 'adaptive'});
      });
    });

    test('start failure closes the hub session and hints', () {
      fakeAsync((a) {
        final t = FakeTransport();
        final hub = HubClient(t);
        final port = FakeSessionPort()..startError = 'boom';
        final st = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: port);
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': 'a', 'path': 'lan', 'port': 5000, 'token': 'tk', 'req': m['req']});
          }
        };
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(t.sent.last, {'cmd': 'close', 'sid': 1});
        expect(st.hint, 'boom');
        expect(st.remote.containsKey(1), false);
      });
    });

    test('end current closes through the port, not the hub', () {
      env((a, t, port, st, hints) {
        st.endCurrent();
        final c = port.calls.last;
        expect(c.$1, 'close');
        expect(c.$2, {'sid': 1});
        expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
      });
    });

    test('runner closed first', () {
      env((a, t, port, st, hints) {
        port.emit(const ClosedEvent(1, 'host says: Calculator quit'));
        expect(st.sessionCount, 0);
        expect(st.hint, 'Calculator 已结束：A 端关闭了 app');
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        expect(st.hint, 'Calculator 已结束：A 端关闭了 app');
        expect(hints.length, 1);
        a.elapse(const Duration(seconds: 2));
        expect(hints.length, 1);
      });
    });

    test('hub closed first', () {
      env((a, t, port, st, hints) {
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        expect(st.sessionCount, 0);
        expect(hints.length, 0);
        a.elapse(const Duration(milliseconds: 200));
        port.emit(const ClosedEvent(1, 'quit'));
        expect(st.hint, '已结束 Calculator');
        expect(hints.length, 1);
        a.elapse(const Duration(seconds: 2));
        expect(hints.length, 1);
        expect(port.calls.where((c) => c.$1 == 'close'), isEmpty);
      });
    });

    test('hub closed and runner silent: hub reason after 1 s and port closed', () {
      env((a, t, port, st, hints) {
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        a.elapse(const Duration(milliseconds: 900));
        expect(hints.length, 0);
        a.elapse(const Duration(milliseconds: 200));
        expect(st.hint, 'Calculator 意外结束：连接断了');
        expect(port.calls.any((c) => c.$1 == 'close' && c.$2['sid'] == 1), true);
      });
    });

    test('decode error ends one session, keeps the other', () {
      env((a, t, port, st, hints) {
        st.select('111/a');
        port.emit(const ClosedEvent(1, 'cannot decode frame: bad tile'));
        expect(st.currentKey, '111/aa');
        expect(st.remote.containsKey(2), true);
        expect(st.sessionCount, 1);
        expect(st.hint, 'Calculator 意外结束：cannot decode frame: bad tile');
      }, sessions: 2);
    });

    test('switching to an open embedded session does not focus through the hub', () {
      env((a, t, port, st, hints) {
        port.emit(const DetachedEvent(1, true));
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(t.sent.where((m) => m['cmd'] == 'focus'), isEmpty);
        final c = port.calls.last;
        expect(c.$1, 'raise_detached');
        expect(c.$2, {'sid': 1});
        expect(st.currentKey, '111/a');
      });
    });

    RemoteWindow rw(int id, {WindowKind kind = WindowKind.normal, double w = 400, double h = 328}) => RemoteWindow(
          id: id,
          parent: 0,
          kind: kind,
          title: 'w$id',
          rect: Rect.fromLTWH(0, 0, w, h),
          titleBar: 28,
          resizable: true,
          focused: false,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    // Records compare their maps by identity: match the call by its parts.
    void lastCall(FakeSessionPort port, String method, Map<String, Object?> args) {
      expect(port.calls.last.$1, method);
      expect(port.calls.last.$2, equals(args));
    }

    test('detach and attach keep the sid and send no open', () {
      env((a, t, port, st, hints) {
        port.emit(const ReadyEvent(1, 'Calculator'));
        port.emit(WindowsEvent(1, [rw(7), rw(9, kind: WindowKind.menu)]));
        st.toggleDetach();
        lastCall(port, 'detach', {'sid': 1});
        expect(st.currentRemote!.detached, false); // only the runner's word moves it
        port.emit(const DetachedEvent(1, true));
        expect(st.currentRemote!.detached, true);
        expect(t.sent.last, {'cmd': 'note', 'sid': 1, 'what': 'detach', 'windows': 1});
        st.toggleDetach();
        lastCall(port, 'attach', {'sid': 1});
        port.emit(const DetachedEvent(1, false, current: 7));
        expect(t.sent.last, {'cmd': 'note', 'sid': 1, 'what': 'attach', 'windows': 1});
        expect(t.sent.where((m) => m['cmd'] == 'open').length, 1);
        expect(port.calls.where((c) => c.$1 == 'start').length, 1);
        expect(st.currentRemote!.sid, 1);
        expect(st.currentRemote!.detached, false);
        expect(st.currentRemote!.tabs.current, 7);
      });
    });

    test('detach and attach act on the current session only', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        port.emit(WindowsEvent(2, [rw(8)]));
        st.select('111/a');
        st.detach();
        lastCall(port, 'detach', {'sid': 1});
        st.attach();
        lastCall(port, 'attach', {'sid': 1});
        st.select('111/aa');
        st.toggleDetach();
        lastCall(port, 'detach', {'sid': 2});
        // Nothing to move yet (no window table): no detach goes out.
        port.emit(const WindowsEvent(2, []));
        final n = port.calls.length;
        st.detach();
        expect(port.calls.length, n);
      }, sessions: 2);
    });

    test('closing the detached window ends the session', () {
      env((a, t, port, st, hints) {
        port.emit(const ReadyEvent(1, 'Calculator'));
        port.emit(WindowsEvent(1, [rw(7)]));
        port.emit(const DetachedEvent(1, true));
        port.emit(const ClosedEvent(1, 'quit'));
        expect(st.sessionCount, 0);
        expect(st.hint, '已结束 Calculator');
      });
    });

    test('detaching takes keyboard focus off the picture', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        st.focusPicture(1);
        port.emit(const DetachedEvent(1, true));
        expect(st.pictureFocused, isNull);
        lastCall(port, 'picture_focus', {'sid': null});
      });
    });

    test('a detached session is not resized from the stage; attach judges once', () {
      env((a, t, port, st, hints) {
        List<Map<String, Object?>> resizes() => port.calls.where((c) => c.$1 == 'resize').map((c) => c.$2).toList();
        st.stageSize(const Size(800, 600));
        port.emit(const ReadyEvent(1, 'Calculator'));
        port.emit(WindowsEvent(1, [rw(7)]));
        expect(resizes().length, 1);
        port.emit(const DetachedEvent(1, true));
        st.stageSize(const Size(900, 600));
        a.elapse(const Duration(seconds: 1));
        // The user resized the detached window: A's size follows it, not the stage.
        port.emit(WindowsEvent(1, [rw(7, w: 500, h: 428)]));
        st.selectWindow(7);
        a.elapse(const Duration(seconds: 1));
        expect(resizes().length, 1);
        port.emit(const DetachedEvent(1, false, current: 7));
        expect(resizes().length, 2);
        expect(resizes().last, {'sid': 1, 'window': 7, 'w': 900, 'h': 600});
        a.elapse(const Duration(seconds: 1));
        expect(resizes().length, 2);
      });
    });

    test('attach with no window left goes back to waiting on the stage (R7)', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        port.emit(const DetachedEvent(1, true));
        port.emit(WindowsEvent(1, [rw(9, kind: WindowKind.menu)]));
        port.emit(const DetachedEvent(1, false));
        expect(st.currentRemote!.detached, false);
        expect(t.sent.last, {'cmd': 'note', 'sid': 1, 'what': 'attach', 'windows': 0});
      });
    });

    test('without a port the S1 path is unchanged', () {
      env((a, t, port, st, hints) {
        expect(st.embeds, false);
        expect(t.sent.where((m) => m['cmd'] == 'open').last.containsKey('embed'), false);
        expect(port.calls.where((c) => c.$1 == 'start'), isEmpty);
        expect(st.remote, isEmpty);
      }, withPort: false);
    });
  });

  group('endedHint', () {
    test('maps runner and hub reasons', () {
      expect(endedHint('X', 'rapp-client: quit'), '已结束 X');
      expect(endedHint('X', 'host says: X quit'), 'X 已结束：A 端关闭了 app');
      expect(endedHint('X', 'connection closed'), 'X 意外结束：连接断了');
      expect(endedHint('X', 'GUI did not connect'), 'X 意外结束：本机没有接上会话');
      expect(endedHint('X', 'rapp-client: boom'), 'X 意外结束：boom');
    });
  });
}
