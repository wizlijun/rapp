import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_choice.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/lifecycle.dart';
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
        var reconnects = 0;
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            final n = (m['app'] as String).length + (m['reconnect'] == true ? 10 * ++reconnects : 0);
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

    List<Map<String, Object?>> sets(FakeSessionPort port, int sid) =>
        [for (final c in port.calls) if (c.$1 == 'set_stream' && c.$2['sid'] == sid) c.$2];

    test('switching away drops to 1 fps and back restores the chosen rate', () {
      env((a, t, port, st, hints) {
        st.select('111/a');
        st.remote[1]!.setChoice(const StreamChoice('color16', 'adaptive', 30));
        expect(sets(port, 1).last['fps'], 30);
        st.select('111/aa');
        expect(sets(port, 1).last['fps'], 1);
        expect(sets(port, 1).last['mode'], 'color16');
        expect(sets(port, 1).last['density'], 'adaptive');
        st.select('111/a');
        expect(sets(port, 1).last['fps'], 30);
        expect(st.remote[1]!.choice.fps, 30);
      }, sessions: 2);
    });

    test('ten sessions: only the current one streams above 1 fps', () {
      env((a, t, port, st, hints) {
        for (var i = 1; i <= 10; i++) {
          final last = sets(port, i).isEmpty ? 15 : sets(port, i).last['fps'];
          expect(last, i == 10 ? 15 : 1, reason: 'session $i');
        }
      }, sessions: 10);
    });

    test('a detached session keeps its rate when another is current', () {
      env((a, t, port, st, hints) {
        // Session 2 is current, so 1 is at 1 fps until it is detached.
        expect(sets(port, 1).last['fps'], 1);
        port.emit(const DetachedEvent(1, true));
        expect(sets(port, 1).last['fps'], 15);
        final n = sets(port, 1).length;
        st.select('111/a');
        st.select('111/aa');
        expect(sets(port, 1).length, n);
        port.emit(const DetachedEvent(1, false));
        expect(sets(port, 1).last['fps'], 1);
      }, sessions: 2);
    });

    test('no duplicate set_stream when nothing changed', () {
      env((a, t, port, st, hints) {
        final n = sets(port, 1).length;
        expect(n, 1);
        st.select('111/aa');
        st.togglePanel();
        st.select('111/aa');
        expect(sets(port, 1).length, n);
        expect(sets(port, 2), isEmpty);
      }, sessions: 2);
    });

    test('a mode change at the same fps is sent', () {
      env((a, t, port, st, hints) {
        st.remote[1]!.setChoice(const StreamChoice('duogray', 'adaptive', 15));
        expect(sets(port, 1).last['mode'], 'duogray');
        expect(sets(port, 1).last['fps'], 15);
        st.remote[1]!.setChoice(const StreamChoice('duogray', 'original', 15));
        expect(sets(port, 1).last['density'], 'original');
      });
    });

    test('an off-stage choice change sends mode at 1 fps; returning sends the chosen rate', () {
      env((a, t, port, st, hints) {
        st.remote[1]!.setChoice(const StreamChoice('duogray', 'original', 30));
        expect(sets(port, 1).last['mode'], 'duogray');
        expect(sets(port, 1).last['density'], 'original');
        expect(sets(port, 1).last['fps'], 1);
        st.select('111/a');
        expect(sets(port, 1).last['fps'], 30);
        expect(sets(port, 1).last['mode'], 'duogray');
      }, sessions: 2);
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

    Map<String, dynamic> embedOpened(int sid, Object? req, {String app = 'a'}) =>
        {...opened(sid, '111', app), 'port': 5000 + sid, 'token': 'tk', 'req': req};

    Iterable<(String, Map<String, Object?>)> closes(FakeSessionPort port, int sid) =>
        port.calls.where((c) => c.$1 == 'close' && c.$2['sid'] == sid);

    test('first frame makes the lamp active, ten quiet seconds make it idle', () {
      env((a, t, port, st, hints) {
        port.emit(const TrafficEvent(1, 900, 0));
        expect(st.current!.lamp, Lamp.connecting);
        port.emit(const TrafficEvent(1, 5000, 2));
        expect(st.current!.lamp, Lamp.active);
        expect(st.current!.bytesPerSecond, 5000);
        for (var i = 0; i < 10; i++) {
          port.emit(const TrafficEvent(1, 0, 0));
        }
        expect(st.current!.lamp, Lamp.idle);
        port.emit(const TrafficEvent(1, 10, 1));
        expect(st.current!.lamp, Lamp.active);
      });
    });

    test('link drop keeps the entry disconnected with a reason', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'the host closed the connection'));
        expect(st.sessionCount, 1);
        expect(st.current!.lamp, Lamp.disconnected);
        expect(st.current!.reason, '网络断了');
        expect(st.current!.bytesPerSecond, isNull);
        expect(st.currentKey, '111/a');
        expect(hints, isEmpty);
        expect(port.calls.where((c) => c.$1 == 'close'), isEmpty);
        expect(st.remote.containsKey(1), true);
      });
    });

    test('A quitting the app reads A 端关闭了 app', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'host says: Calculator quit'));
        expect(st.current!.reason, 'A 端关闭了 app');
      });
    });

    test('disconnect sends close with reason user and reads 你断开了', () {
      env((a, t, port, st, hints) {
        st.disconnectCurrent();
        expect(t.sent.last, {'cmd': 'close', 'sid': 1, 'reason': 'user'});
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'user'});
        a.flushMicrotasks();
        a.elapse(const Duration(milliseconds: 200));
        port.emit(const DisconnectedEvent(1, 'the host closed the connection'));
        expect(st.current!.reason, '你断开了');
        expect(port.calls.where((c) => c.$1 == 'close'), isEmpty);
        a.elapse(const Duration(seconds: 2));
        expect(st.current!.reason, '你断开了');
      });
    });

    test('hub closed first, runner silent: disconnected after 1 s with the hub reason', () {
      env((a, t, port, st, hints) {
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        a.elapse(const Duration(milliseconds: 999));
        expect(st.current!.lamp, isNot(Lamp.disconnected));
        a.elapse(const Duration(milliseconds: 1));
        expect(st.current!.lamp, Lamp.disconnected);
        expect(st.current!.reason, '网络断了');
        expect(port.calls.where((c) => c.$1 == 'close'), isEmpty);
        expect(hints, isEmpty);
      });
    });

    test('hub closed first, then the runner ends it', () {
      env((a, t, port, st, hints) {
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        expect(st.sessionCount, 1);
        a.elapse(const Duration(milliseconds: 200));
        port.emit(const ClosedEvent(1, 'quit'));
        expect(st.sessionCount, 0);
        expect(st.hint, '已结束 Calculator');
        a.elapse(const Duration(seconds: 2));
        expect(hints.length, 1);
      });
    });

    test('runner closed first', () {
      env((a, t, port, st, hints) {
        port.emit(const ClosedEvent(1, 'quit'));
        expect(st.sessionCount, 0);
        expect(st.hint, '已结束 Calculator');
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        expect(hints.length, 1);
        a.elapse(const Duration(seconds: 2));
        expect(hints.length, 1);
      });
    });

    test('decode error disconnects one session, keeps the other', () {
      env((a, t, port, st, hints) {
        st.select('111/a');
        port.emit(const DisconnectedEvent(1, 'cannot decode frame: bad tile'));
        expect(st.recordFor('111/a')!.phase, Phase.disconnected);
        expect(st.current!.reason, 'cannot decode frame: bad tile');
        expect(st.currentKey, '111/a');
        expect(st.remote.containsKey(2), true);
        expect(st.sessionCount, 2);
        expect(hints, isEmpty);
      }, sessions: 2);
    });

    test('start failure closes the hub session quietly and stays disconnected', () {
      fakeAsync((a) {
        final t = FakeTransport();
        final hub = HubClient(t);
        final port = FakeSessionPort()..startError = 'boom';
        final st = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: port);
        final hints = <String>[];
        st.addListener(() => hints.add(st.hint));
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit(embedOpened(1, m['req']));
        };
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 1 && !m.containsKey('reason')), isNotEmpty);
        expect(st.recordFor('111/a')!.phase, Phase.disconnected);
        expect(st.current!.reason, 'boom');
        expect(hints.where((h) => h.isNotEmpty).toList(), ['Calculator 已断开：boom']);
        expect(st.remote.containsKey(1), false);
      });
    });

    test('first open failure stays as a disconnected entry', () {
      fakeAsync((a) {
        final t = FakeTransport();
        final hub = HubClient(t);
        final port = FakeSessionPort();
        final st = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: port);
        final hints = <String>[];
        st.addListener(() => hints.add(st.hint));
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'bad password', 'req': m['req']});
        };
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(st.sessionCount, 1);
        expect(st.current!.lamp, Lamp.disconnected);
        expect(st.current!.reason, '密码不对');
        expect(st.currentKey, '111/a');
        expect(hints.where((h) => h.isNotEmpty).toList(), ['Calculator 已断开：密码不对']);
      });
    });

    test('reconnect opens again with reconnect and keeps choice and window', () {
      env((a, t, port, st, hints) {
        st.remote[1]!.setChoice(const StreamChoice('duogray', 'saver1x', 5));
        port.emit(WindowsEvent(1, [rw(3), rw(7)]));
        st.selectWindow(7);
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        final open = t.sent.where((m) => m['cmd'] == 'open').last;
        expect(open['embed'], true);
        expect(open['reconnect'], true);
        expect(port.calls.last.$1, 'start');
        expect(port.calls.last.$2,
            equals({'sid': 11, 'port': 5011, 'token': 'tk', 'mode': 'duogray', 'fps': 5, 'density': 'saver1x'}));
        expect(st.currentKey, '111/a');
        expect(st.sessionCount, 1);
        expect(closes(port, 1), isEmpty);
        port.emit(WindowsEvent(11, [rw(3), rw(7)]));
        expect(st.remote[11]!.currentWindow, 7);
        expect(closes(port, 1), isNotEmpty);
        expect(st.current!.lamp, Lamp.connecting);
        port.emit(const TrafficEvent(11, 100, 1));
        expect(st.current!.lamp, Lamp.active);
        expect(st.currentRemote!.sid, 11);
      });
    });

    test('reconnect failure goes back to disconnected with the old frame', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'offline', 'req': m['req']});
        };
        st.reconnect('111/a');
        a.flushMicrotasks();
        expect(st.current!.lamp, Lamp.disconnected);
        expect(st.current!.reason, '对方离线');
        expect(st.currentRemote!.sid, 1);
        expect(closes(port, 1), isEmpty);
        expect(hints, ['Calculator 已断开：对方离线']);
      });
    });

    test('opening a disconnected app reconnects it', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(t.sent.where((m) => m['cmd'] == 'open').last['reconnect'], true);
        expect(st.currentKey, '111/a');
      });
    });

    test('end a disconnected session removes it at once', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.endCurrent();
        expect(port.calls.last.$1, 'close');
        expect(port.calls.last.$2, equals({'sid': 1}));
        expect(st.sessionCount, 0);
        expect(hints, ['已结束 Calculator']);
        port.emit(const ClosedEvent(1, 'quit'));
        expect(hints, ['已结束 Calculator']);
      });
    });

    test('end during reconnect closes the new sid quietly', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        t.onSend = (m) {};
        st.reconnect('111/a');
        a.flushMicrotasks();
        final req = t.sent.last['req'];
        st.endCurrent();
        expect(st.sessionCount, 0);
        expect(closes(port, 1), isNotEmpty);
        expect(hints, ['已结束 Calculator']);
        t.emit(embedOpened(11, req));
        a.flushMicrotasks();
        expect(t.sent.last, {'cmd': 'close', 'sid': 11});
        expect(port.calls.where((c) => c.$1 == 'start' && c.$2['sid'] == 11), isEmpty);
        expect(hints, ['已结束 Calculator']);
        t.emit({'event': 'closed', 'sid': 11, 'reason': 'x'});
        a.flushMicrotasks();
        a.elapse(const Duration(seconds: 2));
        expect(hints, ['已结束 Calculator']);
        expect(st.sessionCount, 0);
      });
    });

    test('old sid closed after reconnect is ignored', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(3)]));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(WindowsEvent(11, [rw(3)]));
        port.emit(const TrafficEvent(11, 100, 1));
        hints.clear();
        port.emit(const ClosedEvent(1, 'quit'));
        expect(st.sessionCount, 1);
        expect(st.current!.lamp, Lamp.active);
        expect(hints, isEmpty);
      });
    });

    test('ending a reconnected session before the swap closes both sids once', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        st.endCurrent();
        port.emit(const ClosedEvent(11, 'quit'));
        expect(st.sessionCount, 0);
        expect(closes(port, 1).length, 1);
        expect(closes(port, 11).length, 1);
        expect(st.remote, isEmpty);
      });
    });

    test('old sid closed during reconnect is forgotten: no second close at the swap', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(const ClosedEvent(1, 'quit'));
        expect(st.recordFor('111/a')!.lastSid, isNull);
        port.emit(WindowsEvent(11, [rw(3)]));
        expect(closes(port, 1), isEmpty);
        expect(st.currentRemote!.sid, 11);
      });
    });

    test('new sid disconnecting before the swap closes it and brings the old frame back', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(const DisconnectedEvent(11, 'connection closed'));
        expect(closes(port, 11).length, 1);
        expect(st.current!.lamp, Lamp.disconnected);
        expect(st.currentRemote!.sid, 1);
        expect(st.remote.containsKey(11), false);
        expect(hints, isEmpty);
      });
    });

    test('a disconnect during start is not overwritten when start then fails', () {
      fakeAsync((a) {
        final t = FakeTransport();
        final port = _SlowStartPort();
        final st = MainState(hub: HubClient(t), configDir: tmp.path, prefs: UiPrefs(), port: port);
        final hints = <String>[];
        st.addListener(() => hints.add(st.hint));
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            final sid = m['reconnect'] == true ? 11 : 1;
            t.emit(embedOpened(sid, m['req']));
          }
        };
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        port.release(null); // first start ok
        a.flushMicrotasks();
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(const DisconnectedEvent(11, 'connection closed'));
        hints.clear();
        port.release('boom');
        a.flushMicrotasks();
        expect(st.currentRemote!.sid, 1);
        expect(st.remote.containsKey(1), true);
        expect(st.recordFor('111/a')!.sid, 1);
        expect(hints.where((h) => h.isNotEmpty), isEmpty);
      });
    });

    test('a disconnect during the first start leaves no 已打开 hint', () {
      fakeAsync((a) {
        final t = FakeTransport();
        final port = _SlowStartPort();
        final st = MainState(hub: HubClient(t), configDir: tmp.path, prefs: UiPrefs(), port: port);
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit(embedOpened(1, m['req']));
        };
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        port.release(null);
        a.flushMicrotasks();
        expect(st.hint, isNot(startsWith('已打开')));
        expect(st.current!.lamp, Lamp.disconnected);
      });
    });

    test('hub-first disconnect also clears the transfer line and sending state', () {
      env((a, t, port, st, hints) {
        port.emit(const TransferEvent(1, '下载 x 45%'));
        port.emit(const ComposerStateEvent(1, sending: true));
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        a.elapse(const Duration(seconds: 1));
        expect(st.current!.lamp, Lamp.disconnected);
        expect(st.remote[1]!.transferStatus, isNull);
        expect(st.remote[1]!.composer.sending, false);
      });
    });

    test('a dead sid never reaches the hub or the runner', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        final sent = t.sent.length, calls = port.calls.length;
        port.emit(const DetachedEvent(1, false));
        expect(t.sent.where((m) => m['cmd'] == 'note'), isEmpty);
        st.select('111/a');
        st.select('111/aa');
        expect(t.sent.length, sent);
        expect(port.calls.skip(calls).where((c) => c.$1 == 'set_stream' && c.$2['sid'] == 1), isEmpty);
        expect(hints, isEmpty);
      }, sessions: 2);
    });

    test('attach after the hub dropped the session sends no note', () {
      env((a, t, port, st, hints) {
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        port.emit(const DetachedEvent(1, false));
        expect(t.sent.where((m) => m['cmd'] == 'note'), isEmpty);
      });
    });

    test('detached session disconnecting comes back to the stage', () {
      env((a, t, port, st, hints) {
        port.emit(const DetachedEvent(1, true));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        port.emit(const DetachedEvent(1, false));
        expect(st.remote[1]!.detached, false);
        expect(st.recordFor('111/a')!.phase, Phase.disconnected);
        final notes = t.sent.where((m) => m['cmd'] == 'note').toList();
        expect(notes.length, 1);
        expect(notes.single['what'], 'detach');
      });
    });

    test('total traffic sums live sessions only', () {
      env((a, t, port, st, hints) {
        port.emit(const TrafficEvent(1, 3000, 1));
        port.emit(const TrafficEvent(2, 2000, 1));
        expect(st.totalBytesPerSecond, 5000);
        port.emit(const DisconnectedEvent(2, 'connection closed'));
        expect(st.totalBytesPerSecond, 3000);
        expect(st.disconnectedCount, 1);
      }, sessions: 2);
    });

    test('hub exiting disconnects embedded sessions', () {
      env((a, t, port, st, hints) {
        t.die();
        a.flushMicrotasks();
        a.elapse(const Duration(seconds: 1));
        expect(st.current!.lamp, Lamp.disconnected);
        expect(st.current!.reason, disconnectWord('rapp-hub exited'));
        final sent = t.sent.length, calls = port.calls.length;
        st.reconnect('111/a');
        a.flushMicrotasks();
        expect(t.sent.length, sent);
        expect(port.calls.length, calls);
      });
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

    test('切到窗口 on a detached session goes to the runner, and needs no hub to', () {
      env((a, t, port, st, hints) {
        port.emit(const ReadyEvent(1, 'Calculator'));
        port.emit(WindowsEvent(1, [rw(7)]));
        port.emit(const DetachedEvent(1, true));
        final sent = t.sent.length;
        st.focusCurrent();
        lastCall(port, 'raise_detached', {'sid': 1});
        expect(t.sent.length, sent);
        // The hub going away takes its session list with it: there is no current session left to
        // raise (the stage shows the hub's problem), and nothing is sent anywhere.
        t.die();
        a.flushMicrotasks();
        a.elapse(const Duration(seconds: 1));
        expect(st.hubUsable, isFalse);
        // The record stays, disconnected; nothing is sent to the hub.
        expect(st.currentDisconnected, true);
        final calls = port.calls.length;
        st.focusCurrent();
        expect(t.sent.length, sent);
        expect(port.calls.skip(calls).where((c) => c.$1 == 'raise_detached'), isEmpty);
      });
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

/// A port whose `start` waits for the test to release it (null: ok, else the error thrown).
class _SlowStartPort extends FakeSessionPort {
  final _starts = <Completer<Object?>>[];

  void release(Object? error) {
    final c = _starts.removeAt(0);
    error == null ? c.complete(null) : c.completeError(error);
  }

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) {
    if (method != 'start') return super.invoke(method, args);
    calls.add((method, args));
    final c = Completer<Object?>();
    _starts.add(c);
    return c.future;
  }
}
