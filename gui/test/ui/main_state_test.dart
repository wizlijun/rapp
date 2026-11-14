import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/app_profile_store.dart';
import 'package:rapp/embed/stream_choice.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/lifecycle.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/pin_files.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/resources_state.dart';
import 'package:rapp/ui/session_model.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/workspace_store.dart';

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
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
  });

  tearDown(() {
    Process.runSync('chmod', ['755', tmp.path]);
    tmp.deleteSync(recursive: true);
  });

  test('relocate reads the workspace of the new root', () {
    final other = Directory.systemTemp.createTempSync('main_state_reloc');
    addTearDown(() => other.deleteSync(recursive: true));
    final d = DataDir(other.path);
    Directory(d.sharedDir).createSync(recursive: true);
    saveWorkspace(d.sharedDir, Workspace()..favorites.add(AppRef('111', 'b', 'N')));
    var n = 0;
    s.addListener(() => n++);
    s.relocate(d);
    expect(s.data.root, other.path);
    expect(s.favorites.map((f) => f.key), ['111/b']);
    expect(n, greaterThan(0));
    File('${d.sharedDir}/workspace.json').writeAsStringSync('nope');
    s.relocate(d);
    expect(s.hint, loadProblem);
    expect(s.favorites, isEmpty);
  });

  int opens() => t.sent.where((m) => m['cmd'] == 'open').length;

  Map<String, dynamic> opened(int sid, String id, String app) =>
      {'event': 'opened', 'sid': sid, 'id': id, 'app': app, 'path': 'lan'};

  test('workspace is read from and saved to shared/', () {
    final root = Directory.systemTemp.createTempSync('rapp-data');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/shared').createSync();
    File('${root.path}/shared/workspace.json').writeAsStringSync(
        '{"version":1,"favorites":[{"device":"1","bundle":"b","name":"n"}],"projects":[]}');
    final s2 = MainState(hub: hub, data: DataDir(root.path), prefs: UiPrefs());
    expect(s2.workspace.favorites.single.bundle, 'b');
    s2.toggleFavorite('2', 'c', 'C');
    final saved = File('${root.path}/shared/workspace.json').readAsStringSync();
    expect('"bundle"'.allMatches(saved).length, 2);
    expect(File('${root.path}/workspace.json').existsSync(), false);
  });

  test('prefs go to devices/<id>/gui.json, and are not written without an id', () {
    final root = Directory.systemTemp.createTempSync('rapp-data');
    addTearDown(() => root.deleteSync(recursive: true));
    final s2 = MainState(hub: hub, data: DataDir(root.path), prefs: UiPrefs());
    s2.setTheme(RappTheme.avatar);
    expect(Directory('${root.path}/devices').existsSync() && Directory('${root.path}/devices').listSync().isNotEmpty, false);
    Directory('${root.path}/local').createSync();
    File('${root.path}/local/service.json').writeAsStringSync('{"id":"123456789"}');
    s2.setTheme(RappTheme.westworld);
    final j = File('${root.path}/devices/123456789/gui.json').readAsStringSync();
    expect(j, contains(RappTheme.westworld.name));
  });

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
    expect(s.hint, '对方离线');
  });

  test('an open the relay refused for its key says what to do, in Chinese', () async {
    for (final (error, word) in [
      ('key changed', '中继换了 key，请到 本机 → 输入新 key'),
      ('bad key', 'key 不对'),
    ]) {
      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': error, 'req': m['req']});
      };
      await s.openOrSwitch('111', 'a', 'A');
      expect(s.hint, word, reason: error);
    }
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

  test('setTheme survives an unwritable devices dir', () async {
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    File('${tmp.path}/devices').writeAsStringSync('x'); // devices/dev1 cannot be created
    final s2 = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
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
    final s2 = MainState(hub: null, hubError: 'boom', data: DataDir(tmp.path), prefs: UiPrefs());
    expect(s2.hubProblem, 'boom');
    expect(s2.hubUsable, isFalse);
  });

  group('route', () {
    test('setRelaySet notifies only on a change', () {
      var n = 0;
      s.addListener(() => n++);
      expect(s.relaySet, isFalse);
      s.setRelaySet(false);
      expect(n, 0);
      s.setRelaySet(true);
      expect([s.relaySet, n], [true, 1]);
      s.setRelaySet(true);
      expect(n, 1);
    });

    test('pathOf prefers the hub\'s path event over the probe', () async {
      t.onSend = (m) {
        if (m['cmd'] == 'apps') t.emit({'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'relay', 'apps': []});
      };
      expect(s.pathOf('111'), isNull);
      await s.probe('111');
      expect(s.pathOf('111'), 'relay');
      var n = 0;
      s.addListener(() => n++);
      t.emit({'event': 'path', 'id': '111', 'path': 'lan'});
      await pump();
      expect(s.pathOf('111'), 'lan');
      expect(n, greaterThan(0));
      expect(hub.takePaths(), isEmpty, reason: 'MainState drains the queue');
    });

    test('forcedRelay follows the hosts list; setRoute sends relay or auto', () async {
      t.onSend = (m) {
        if (m['cmd'] == 'set_route') {
          t.emit({
            'event': 'hosts',
            'req': m['req'],
            'hosts': [
              {'id': '111', 'name': 'mini', if (m['route'] == 'relay') 'route': 'relay'},
              {'id': '222', 'name': ''},
            ],
          });
        }
      };
      expect(s.forcedRelay('111'), isFalse);
      await s.setRoute('111', true);
      expect(t.sent.last, {'cmd': 'set_route', 'id': '111', 'route': 'relay', 'req': anything});
      expect(s.forcedRelay('111'), isTrue);
      expect(s.forcedRelay('222'), isFalse);
      await s.setRoute('111', false);
      expect(t.sent.last['route'], 'auto');
      expect(s.forcedRelay('111'), isFalse);
    });

    test('a failed setRoute puts the reason in the hint', () async {
      t.onSend = (m) {
        if (m['cmd'] == 'set_route') t.emit({'event': 'error', 'req': m['req'], 'error': 'relay unreachable: timed out'});
      };
      await s.setRoute('111', true);
      expect(s.hint, '中继连不上');
    });

    test('an offline presence keeps its error on the probe', () async {
      t.emit({'event': 'presence', 'id': '111', 'online': false, 'error': 'relay unreachable: timed out'});
      await pump();
      expect(s.probes['111']!.lamp, Lamp.offline);
      expect(s.probes['111']!.error, 'relay unreachable: timed out');
      t.emit({'event': 'presence', 'id': '111', 'online': true});
      await pump();
      expect(s.probes['111']!.error, isNull);
    });
  });

  group('project batch, S1 path', () {
    Project project(List<AppRef> apps) {
      final p = s.createProject('写周报')!;
      for (final a in apps) {
        s.addMember(p.id, a);
      }
      return p;
    }

    const safari = AppRef('111', 'com.apple.Safari', 'Safari');
    const notes = AppRef('111', 'com.apple.Notes', 'Notes');

    test('open all on the S1 path opens pending entries once', () async {
      final p = project([safari, notes]);
      s.openAll(p.id);
      await pump();
      expect(opens(), 2);
      expect(s.entryFor(safari.key)!.lamp, Lamp.connecting);
      expect(s.entryFor(notes.key)!.lamp, Lamp.connecting);
      expect(s.currentKey, safari.key);
      expect(s.hint, '写周报：打开 2 个');
      s.openAll(p.id);
      await pump();
      expect(opens(), 2);
      expect(s.hint, '写周报：已经全部打开');
      // The opens land quietly: no 「已打开」 over the summary.
      for (final m in t.sent.where((m) => m['cmd'] == 'open').toList()) {
        t.emit({...opened(m['app'] == safari.bundle ? 1 : 2, '111', m['app'] as String), 'req': m['req']});
      }
      await pump();
      expect(s.entryFor(safari.key)!.lamp, Lamp.active);
      expect(s.hint, '写周报：已经全部打开');
    });

    test('open all on the S1 path: a failed stop goes to no session', () async {
      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'offline', 'req': m['req']});
      };
      final p = project([safari]);
      s.openAll(p.id);
      expect(s.currentKey, safari.key);
      await pump();
      expect(s.currentKey, isNull);
      expect(s.hint, '对方离线');
    });

    test('end all on the S1 path closes by sid and stays quiet', () async {
      t.emit(opened(1, '111', safari.bundle));
      t.emit(opened(2, '111', notes.bundle));
      await pump();
      final p = project([safari, notes]);
      s.endAll(p.id);
      expect(t.sent.where((m) => m['cmd'] == 'close').map((m) => m['sid']), [1, 2]);
      expect(s.hint, '写周报：结束 2 个会话');
      t.emit({'event': 'closed', 'sid': 1});
      t.emit({'event': 'closed', 'sid': 2});
      await pump();
      expect(s.hint, '写周报：结束 2 个会话');
      expect(s.sessionCount, 0);
    });

    test('end all skips an S1 entry still opening', () async {
      final p = project([safari]);
      s.openOrSwitch(safari.device, safari.bundle, safari.name);
      await pump();
      expect(s.entryFor(safari.key)!.lamp, Lamp.connecting);
      s.endAll(p.id);
      expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
      expect(s.hint, '写周报：没有要结束的会话');
    });

    test('endCurrent still hints as before', () async {
      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit({...opened(1, '111', safari.bundle), 'req': m['req']});
      };
      await s.openOrSwitch(safari.device, safari.bundle, safari.name);
      s.select(safari.key);
      s.endCurrent();
      expect(s.hint, '正在结束 Safari');
      expect(t.sent.last, {'cmd': 'close', 'sid': 1});
      t.emit({'event': 'closed', 'sid': 1, 'reason': 'stdin closed'});
      await pump();
      expect(s.hint, '已结束 Safari');
    });
  });

  group('workspace', () {
    MainState restart() => MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());

    test('a bad workspace file shows the load problem as the hint', () {
      Directory('${tmp.path}/shared').createSync();
      File('${tmp.path}/shared/workspace.json').writeAsStringSync('{bad');
      final s2 = restart();
      expect(s2.hint, '项目和常用没有读到，已从空白开始');
      expect(s2.favorites, isEmpty);
    });

    test('toggleFavorite saves and survives a restart', () {
      s.toggleFavorite('111', 'com.apple.calculator', 'Calculator');
      expect(s.isFavorite('111', 'com.apple.calculator'), true);
      expect(restart().favorites.single.name, 'Calculator');
      s.toggleFavorite('111', 'com.apple.calculator', 'Calculator');
      expect(s.isFavorite('111', 'com.apple.calculator'), false);
      expect(restart().favorites, isEmpty);
      expect(s.hint, '');
    });

    test('idle favorites leave out open and pending sessions', () async {
      s.toggleFavorite('111', 'com.apple.Safari', 'Safari');
      s.toggleFavorite('111', 'com.apple.Notes', 'Notes');
      s.openOrSwitch('111', 'com.apple.Safari', 'Safari');
      expect(s.idleFavorites.map((a) => a.bundle), ['com.apple.Notes']);
      t.emit({...opened(1, '111', 'com.apple.Safari'), 'req': t.sent.last['req']});
      await pump();
      expect(s.idleFavorites.map((a) => a.bundle), ['com.apple.Notes']);
      t.emit({'event': 'closed', 'sid': 1});
      await pump();
      expect(s.idleFavorites.map((a) => a.bundle), ['com.apple.Safari', 'com.apple.Notes']);
    });

    test('removing a device drops only its favorites', () async {
      t.onSend = (m) {
        if (m['cmd'] == 'remove_host') {
          t.emit({
            'event': 'hosts',
            'req': m['req'],
            'hosts': [
              {'id': '222', 'name': ''},
            ],
          });
        }
      };
      s.toggleFavorite('111', 'x', 'X');
      s.toggleFavorite('222', 'y', 'Y');
      await s.removeDevice('111');
      expect(s.favorites.map((a) => a.key), ['222/y']);
      expect(restart().favorites.map((a) => a.key), ['222/y']);
    });

    test('an unwritable dir keeps the data in memory and says why', () {
      Process.runSync('chmod', ['555', tmp.path]);
      s.toggleFavorite('111', 'x', 'X');
      expect(s.isFavorite('111', 'x'), true);
      expect(s.hint, startsWith('项目和常用没有保存：'));
      expect(File('${tmp.path}/shared/workspace.json').existsSync(), false);
    });
  });

  group('embedded sessions', () {
    void env(void Function(FakeAsync a, FakeTransport t, FakeSessionPort port, MainState st, List<String> hints) body,
        {int sessions = 1, bool withPort = true, AppProfileStore? profiles, void Function(String)? log, String? app}) {
      fakeAsync((a) {
        final t = FakeTransport();
        final hub = HubClient(t);
        final port = FakeSessionPort();
        final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: withPort ? port : null, profiles: profiles, log: log);
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
        if (app != null) {
          st.openOrSwitch('111', app, 'App');
          a.flushMicrotasks();
        } else {
          for (var i = 1; i <= sessions; i++) {
            st.openOrSwitch('111', 'a' * i, i == 1 ? 'Calculator' : 'Notes');
            a.flushMicrotasks();
          }
        }
        hints.clear();
        body(a, t, port, st, hints);
      });
    }

  group('app profiles', () {
    String shared() => '${tmp.path}/shared';
    AppProfileStore store({List<AppProfile> mine = const []}) => AppProfileStore(shared(), mine: [...mine], builtin: [
          AppProfile(ids: ['com.apple.Terminal'], name: '终端', mode: 'duogray', density: 'adaptive', fps: 15, composer: true),
        ]);

    RemoteWindow w(int id, {WindowKind kind = WindowKind.normal, String? title}) => RemoteWindow(
          id: id,
          parent: 0,
          kind: kind,
          title: title ?? 'w$id',
          rect: const Rect.fromLTWH(0, 0, 400, 300),
          titleBar: 28,
          resizable: true,
          focused: false,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    List<(String, Map<String, Object?>)> calls(FakeSessionPort p, String m) => [for (final c in p.calls) if (c.$1 == m) c];
    const chrome = 'com.google.Chrome';
    AppProfile chromeWith({List<WindowRule>? windows, AfterSend? afterSend}) =>
        AppProfile(ids: [chrome], name: 'Chrome', windows: windows, afterSend: afterSend);
    const hideFloating = WindowRule(kind: WindowKind.floating, action: RuleAction.hide);

    test('a new session starts with the profile stream; reconnect keeps the session choice', () {
      final sid = 'com.apple.Terminal'.length;
      env((a, t, port, st, hints) {
        expect(calls(port, 'start').first.$2, containsPair('mode', 'duogray'));
        st.currentRemote!.setChoice(const StreamChoice('color16', 'original', 30));
        port.emit(DisconnectedEvent(sid, 'connection closed'));
        st.reconnect('111/com.apple.Terminal');
        a.flushMicrotasks();
        expect(calls(port, 'start').last.$2, allOf(containsPair('mode', 'color16'), containsPair('fps', 30)));
      }, app: 'com.apple.Terminal', profiles: store());
    });

    test('no profile: the generic start choice', () {
      env((a, t, port, st, hints) {
        expect(calls(port, 'start').first.$2, allOf(containsPair('mode', 'color16'), containsPair('fps', 15)));
      }, app: 'com.unknown', profiles: store());
    });

    test('hideLike hides at once, sends set_hidden, and undo brings it back', () {
      final sid = chrome.length;
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(sid, [w(1), w(2, kind: WindowKind.floating, title: 'Downloads')]));
        final undo = st.hideLike(2)!;
        expect(st.currentRemote!.tabs.tabs.map((e) => e.id), [1]);
        expect(port.calls.last.$1, 'set_hidden');
        expect(port.calls.last.$2, {'sid': sid, 'windows': [2]});
        expect(st.profiles.mine.single.windows!.first,
            const WindowRule(kind: WindowKind.floating, title: 'Downloads', action: RuleAction.hide));
        undo();
        expect(st.currentRemote!.tabs.tabs.map((e) => e.id), [1, 2]);
        expect(port.calls.last.$1, 'set_hidden');
        expect(port.calls.last.$2, {'sid': sid, 'windows': <int>[]});
      }, app: chrome, profiles: store());
    });

    test('closing a tab closes its window; closing a sheet presses Esc', () {
      final sid = chrome.length;
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(sid, [w(1), w(2, kind: WindowKind.floating), w(3, kind: WindowKind.sheet)]));
        st.closeWindow(2);
        expect(calls(port, 'close_window').single.$2, {'sid': sid, 'window': 2});
        st.closeWindow(3);
        expect(calls(port, 'key').single.$2, {'sid': sid, 'keyCode': 53, 'modifiers': 0});
        st.closeWindow(99); // not in the table
        expect(calls(port, 'close_window').length + calls(port, 'key').length, 2);
      }, app: chrome, profiles: store());
    });

    test('marking the input box saves a point in the profile; the session clicks it before sending', () {
      final sid = chrome.length;
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(sid, [w(1)]));
        st.markInputAt(const Offset(100, 250), const Size(400, 272)); // not marking: ignored
        expect(st.currentRemote!.profile.input, isNull);
        st.markInput();
        expect(st.markingInput, sid);
        st.markInputAt(const Offset(100, 250), const Size(400, 272));
        expect(st.markingInput, isNull);
        final p = st.currentRemote!.profile.input!;
        expect((p.x, p.dy, p.fromBottom), (0.25, 22.0, true));
        expect(st.hint, '已标记输入区：发送前会先点它');
        port.calls.clear();
        st.currentRemote!.prepareInput();
        expect([for (final c in port.calls) c.$1], ['mouse', 'mouse']);
        expect(port.calls.first.$2, containsPair('x', 100.0));
        expect(port.calls.first.$2, containsPair('y', 28 + 250.0));
        st.clearInputMark();
        expect(st.currentRemote!.profile.input, isNull);
      }, app: chrome, profiles: store());
    });

    test('hideLike on the main window does nothing; noComposerLike there writes child: false', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(chrome.length, [w(1), w(2)]));
        expect(st.hideLike(1), isNull);
        expect(st.isMainWindow(1), true);
        st.noComposerLike(1);
        expect(st.profiles.mine.single.windows!.first.child, isFalse);
      }, app: chrome, profiles: store());
    });

    test('a profile change while detached sends set_hidden at once', () {
      final sid = chrome.length;
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(sid, [w(1), w(2, kind: WindowKind.floating)]));
        port.emit(DetachedEvent(sid, true));
        st.profiles.addRule(chrome, 'Chrome', hideFloating);
        expect(port.calls.last.$1, 'set_hidden');
        expect(port.calls.last.$2, {'sid': sid, 'windows': [2]});
      }, app: chrome, profiles: store());
    });

    test('set_hidden is not sent again for the same set', () {
      final sid = chrome.length;
      env((a, t, port, st, hints) {
        final table = [w(1), w(2, kind: WindowKind.floating)];
        port.emit(WindowsEvent(sid, table));
        port.emit(WindowsEvent(sid, table));
        expect(calls(port, 'set_hidden').length, 1);
      }, app: chrome, profiles: store(mine: [chromeWith(windows: [hideFloating])]));
    });

    test('showHiddenOnce and unhide', () {
      final sid = chrome.length;
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(sid, [w(1), w(2, kind: WindowKind.floating)]));
        expect(st.currentRemote!.hidden, isNotEmpty);
        st.showHiddenOnce(2);
        expect(st.currentRemote!.hidden, isEmpty);
        st.unhide(2);
        expect(st.profiles.resolve(chrome).windows, isEmpty);
        expect(st.hint, '不再隐藏这类窗口');
      }, app: chrome, profiles: store(mine: [chromeWith(windows: [hideFloating])]));
    });

    test('afterSend return sends key 36 after a full round only', () {
      final sid = chrome.length;
      env((a, t, port, st, hints) {
        final rs = st.currentRemote!;
        rs.composer.text = 'ls';
        rs.composer.send();
        port.emit(ComposerStateEvent(sid, done: const ComposerDone(1, null)));
        expect(calls(port, 'key').single.$2, {'sid': sid, 'keyCode': 36, 'modifiers': 0});
        rs.composer.text = 'x';
        rs.composer.send();
        port.emit(ComposerStateEvent(sid, done: const ComposerDone(0, 'A 上贴不进去')));
        expect(calls(port, 'key').length, 1);
      }, app: chrome, profiles: store(mine: [chromeWith(afterSend: AfterSend.pressReturn)]));
    });

    test('rememberStream writes the current choice into my profile', () {
      env((a, t, port, st, hints) {
        st.currentRemote!.setChoice(const StreamChoice('duocolor', 'original', 5));
        st.rememberStream();
        expect(st.profiles.resolve('com.apple.Terminal').stream, const StreamChoice('duocolor', 'original', 5));
        expect(st.hint, '已记为 终端 的默认');
      }, app: 'com.apple.Terminal', profiles: store());
    });

    test('logs name the profile and the count, never a title or a pattern (D9)', () {
      final lines = <String>[];
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(chrome.length, [
          w(1, title: '我的秘密文件.pdf'),
          w(2, kind: WindowKind.floating, title: '秘密 下载'),
        ]));
        expect(lines, ['rapp: app 配置「Chrome」', 'rapp: app 配置「Chrome」：隐藏 1 个窗口']);
        for (final l in lines) {
          expect(l, isNot(contains('秘密')));
          expect(l, isNot(contains('pdf')));
          expect(l, isNot(contains('*')));
        }
      },
          app: chrome,
          log: lines.add,
          profiles: store(mine: [
            chromeWith(windows: [const WindowRule(kind: WindowKind.floating, title: '*秘密*', action: RuleAction.hide)])
          ]));
    });

    test('a broken apps.json at start shows the hint', () {
      Directory(shared()).createSync(recursive: true);
      File('${shared()}/apps.json').writeAsStringSync('[');
      final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
      expect(st.hint, contains(appsLoadProblem));
    });

    test('relocate reloads apps.json from the new root and keeps the built-ins', () {
      final other = Directory.systemTemp.createTempSync('main_state_reloc2');
      addTearDown(() => other.deleteSync(recursive: true));
      final d = DataDir(other.path);
      final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), profiles: store());
      Directory(d.sharedDir).createSync(recursive: true);
      File('${d.sharedDir}/apps.json').writeAsStringSync(
          '{"version":1,"apps":[{"ids":["com.x"],"name":"X","stream":{"mode":"duocolor","density":"adaptive","fps":5}}]}');
      st.relocate(d);
      expect(st.profiles.dir, d.sharedDir);
      expect(st.profiles.resolve('com.x').name, 'X');
      expect(st.profiles.resolve('com.apple.Terminal').name, '终端');
      var n = 0;
      st.addListener(() => n++);
      st.profiles.addRule('com.x', 'X', hideFloating);
      expect(n, greaterThan(0));
    });
  });

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

    test('manual pick pins and reaches the port; a plain choice does not', () {
      env((a, t, port, st, hints) {
        st.currentRemote!.setChoice(const StreamChoice('duogray', 'adaptive', 1));
        expect(port.calls.last.$2['pinned'], isNot(true));
        st.currentRemote!.setChoice(const StreamChoice('color16', 'adaptive', 5), manual: true);
        expect(port.calls.last.$1, 'set_stream');
        expect(port.calls.last.$2['pinned'], true);
      });
    });

    group('automatic reconnect', () {
      int opens(FakeTransport t) => t.sent.where((m) => m['cmd'] == 'open').length;
      void failOpens(FakeTransport t) {
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'offline', 'req': m['req']});
        };
      }

      test('network drop reconnects after 1s', () {
        env((a, t, port, st, hints) {
          final before = opens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(milliseconds: 999));
          expect(opens(t), before);
          a.elapse(const Duration(milliseconds: 1));
          a.flushMicrotasks();
          expect(opens(t), before + 1);
          expect(t.sent.where((m) => m['cmd'] == 'open').last['reconnect'], true);
          expect(st.currentRecord!.retry, isNull);
        });
      });

      test('backoff 1,2,4,8,15,15', () {
        env((a, t, port, st, hints) {
          final times = <int>[];
          final start = a.getClock(DateTime(2026)).now();
          failOpens(t);
          final inner = t.onSend!;
          t.onSend = (m) {
            if (m['cmd'] == 'open') times.add(a.getClock(DateTime(2026)).now().difference(start).inSeconds);
            inner(m);
          };
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 60));
          expect(times.take(6).toList(), [1, 3, 7, 15, 30, 45]);
        });
      });

      test('no hint on failed auto attempts', () {
        env((a, t, port, st, hints) {
          failOpens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 8));
          expect(hints, isEmpty);
          expect(st.currentRecord!.retry, isNotNull);
        });
      });

      test('success resets backoff', () {
        env((a, t, port, st, hints) {
          final send = t.onSend!;
          failOpens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 4)); // tries at 1 s and 3 s failed; next waits 4 s
          t.onSend = send;
          a.elapse(const Duration(seconds: 3));
          a.flushMicrotasks();
          expect(st.currentRecord!.retry, isNull);
          expect(st.currentRecord!.phase, Phase.live);
          final n = opens(t);
          port.emit(const DisconnectedEvent(11, 'connection closed'));
          a.elapse(const Duration(milliseconds: 999));
          expect(opens(t), n);
          a.elapse(const Duration(milliseconds: 1));
          expect(opens(t), n + 1);
        });
      });

      for (final reason in ['user', 'host says: app quit', 'host says: taken over by X']) {
        test('"$reason" does not retry', () {
          env((a, t, port, st, hints) {
            final n = opens(t);
            port.emit(DisconnectedEvent(1, reason));
            a.elapse(const Duration(seconds: 60));
            expect(opens(t), n);
            expect(st.currentRecord!.retry, isNull);
          });
        });
      }

      test('bad password stops retrying', () {
        env((a, t, port, st, hints) {
          t.onSend = (m) {
            if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'bad password', 'req': m['req']});
          };
          final n = opens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 60));
          expect(opens(t), n + 1);
          expect(st.currentRecord!.retry, isNull);
          expect(st.hint, '${st.currentRecord!.appName} 已断开：密码不对');
        });
      });

      test('stop cancels', () {
        env((a, t, port, st, hints) {
          failOpens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 2));
          expect(st.currentRecord!.retry, isNotNull);
          st.stopReconnectCurrent();
          final n = opens(t);
          a.elapse(const Duration(seconds: 60));
          expect(opens(t), n);
          expect(st.currentRecord!.retry, isNull);
          expect(st.currentRecord!.phase, Phase.disconnected);
        });
      });

      test('end session while waiting cancels', () {
        env((a, t, port, st, hints) {
          failOpens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 2));
          st.endSession('111/a');
          expect(st.recordFor('111/a'), isNull);
          final n = opens(t);
          a.elapse(const Duration(seconds: 60));
          expect(opens(t), n);
        });
      });

      test('manual reconnect while waiting opens once now', () {
        env((a, t, port, st, hints) {
          final n = opens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(milliseconds: 500));
          st.reconnect('111/a');
          a.flushMicrotasks();
          expect(opens(t), n + 1);
          a.elapse(const Duration(seconds: 60));
          expect(opens(t), n + 1);
        });
      });

      test('a manual reconnect that fails for a password shows its hint and does not retry', () {
        env((a, t, port, st, hints) {
          port.emit(const DisconnectedEvent(1, 'user'));
          t.onSend = (m) {
            if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'bad password', 'req': m['req']});
          };
          final n = opens(t);
          st.reconnect('111/a');
          a.flushMicrotasks();
          a.elapse(const Duration(seconds: 60));
          expect(opens(t), n + 1);
          expect(hints, ['Calculator 已断开：密码不对']);
        });
      });

      test('a manual reconnect that fails offline says so once and keeps waiting', () {
        env((a, t, port, st, hints) {
          port.emit(const DisconnectedEvent(1, 'user'));
          failOpens(t);
          final n = opens(t);
          st.reconnect('111/a');
          a.flushMicrotasks();
          expect(st.currentRecord!.retry, isNotNull);
          a.elapse(const Duration(seconds: 60));
          expect(opens(t), greaterThan(n + 3));
          expect(hints, ['Calculator 已断开：对方离线']);
        });
      });

      test('a first open that fails offline waits and opens when it can', () {
        env((a, t, port, st, hints) {
          final send = t.onSend!;
          failOpens(t);
          st.openOrSwitch('222', 'b', 'Notes');
          a.flushMicrotasks();
          final r = st.recordFor('222/b')!;
          expect(r.phase, Phase.disconnected);
          expect(r.retry, isNotNull);
          t.onSend = send;
          a.elapse(const Duration(seconds: 2));
          a.flushMicrotasks();
          expect(st.recordFor('222/b')!.phase, Phase.live);
        });
      });

      test('relay unreachable reconnects by itself', () {
        env((a, t, port, st, hints) {
          final n = opens(t);
          port.emit(const DisconnectedEvent(1, 'relay unreachable: timed out'));
          a.elapse(const Duration(seconds: 1));
          a.flushMicrotasks();
          expect(opens(t), n + 1);
        });
      });

      test('stop during an in-flight attempt: the open then succeeds, the record stays disconnected', () {
        env((a, t, port, st, hints) {
          final send = t.onSend!;
          Map<String, Object?>? held;
          t.onSend = (m) {
            if (m['cmd'] == 'open') {
              held = m;
            } else {
              send(m);
            }
          };
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 1));
          expect(held, isNotNull);
          expect(st.currentRecord!.phase, Phase.connecting);
          st.stopReconnectCurrent();
          expect(st.currentRecord!.retry, isNull);
          t.emit({'event': 'opened', 'sid': 11, 'id': '111', 'app': 'a', 'path': 'lan', 'port': 5011, 'token': 'tk', 'req': held!['req']});
          a.flushMicrotasks();
          expect(st.currentRecord!.phase, Phase.disconnected);
          expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 11), isNotEmpty);
          expect(port.calls.where((c) => c.$1 == 'start'), hasLength(1)); // the first session's only
          final n = opens(t);
          a.elapse(const Duration(seconds: 60));
          expect(opens(t), n);
          expect(st.currentRecord!.retry, isNull);
          expect(hints, isEmpty);
        });
      });

      test('stop during an in-flight attempt: the open then fails, no hint, no retry', () {
        env((a, t, port, st, hints) {
          Map<String, Object?>? held;
          t.onSend = (m) {
            if (m['cmd'] == 'open') held = m;
          };
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 1));
          st.stopReconnectCurrent();
          t.emit({'event': 'error', 'error': 'offline', 'req': held!['req']});
          a.flushMicrotasks();
          expect(st.currentRecord!.phase, Phase.disconnected);
          final n = opens(t);
          a.elapse(const Duration(seconds: 60));
          expect(opens(t), n);
          expect(hints, isEmpty);
        });
      });

      for (final reason in ['bad token', 'host says: taken over by X', 'host says: Calculator quit']) {
        test('attempt 1 failing with "$reason" stops retrying', () {
          env((a, t, port, st, hints) {
            var tries = 0;
            t.onSend = (m) {
              if (m['cmd'] == 'open') {
                t.emit({'event': 'error', 'error': ++tries == 1 ? 'offline' : reason, 'req': m['req']});
              }
            };
            port.emit(const DisconnectedEvent(1, 'connection closed'));
            a.elapse(const Duration(seconds: 60));
            expect(tries, 2);
            expect(st.currentRecord!.retry, isNull);
          });
        });
      }

      test('auto reconnect keeps a pin', () {
        env((a, t, port, st, hints) {
          st.currentRemote!.setChoice(const StreamChoice('duogray', 'saver1x', 5), manual: true);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 1));
          a.flushMicrotasks();
          expect(port.calls.last.$1, 'set_stream');
          expect(port.calls.last.$2['pinned'], true);
        });
      });
    });

    test('pin survives reconnect', () {
      env((a, t, port, st, hints) {
        st.currentRemote!.setChoice(const StreamChoice('duogray', 'saver1x', 5), manual: true);
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        expect(port.calls.last.$1, 'set_stream');
        expect(port.calls.last.$2, containsPair('sid', 11));
        expect(port.calls.last.$2['pinned'], true);
        expect(st.remote[11]!.streamPinned, true);
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

    test('input blocked shows for a second on the current session only', () {
      env((a, t, port, st, hints) {
        port.emit(const InputBlockedEvent(1, 'Mac mini'));
        expect(st.hint, '远端正在被 Mac mini 操作');
        a.elapse(const Duration(milliseconds: 999));
        expect(st.hint, '远端正在被 Mac mini 操作');
        a.elapse(const Duration(milliseconds: 1));
        expect(st.hint, isNot('远端正在被 Mac mini 操作'));
        port.emit(const InputBlockedEvent(1, ''));
        expect(st.hint, '远端正在被另一台设备操作');
      });
      env((a, t, port, st, hints) {
        // sid 2 is Notes; Calculator (sid 10) is not on the stage once Notes is current.
        expect(st.currentKey, '111/aa');
        final before = st.hint;
        port.emit(const InputBlockedEvent(10, 'Mac mini'));
        expect(st.hint, before);
      }, sessions: 2);
    });

    test('a second blocked event re-arms the 1 s hint', () {
      env((a, t, port, st, hints) {
        const text = '远端正在被 Mac mini 操作';
        port.emit(const InputBlockedEvent(1, 'Mac mini'));
        a.elapse(const Duration(milliseconds: 600));
        port.emit(const InputBlockedEvent(1, 'Mac mini'));
        a.elapse(const Duration(milliseconds: 600)); // the first timer would have cleared it at 1000
        expect(st.hint, text);
        a.elapse(const Duration(milliseconds: 400));
        expect(st.hint, isNot(text));
      });
    });

    test('a taken over session stays disconnected, counts in needs, does not reconnect by itself', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'host says: taken over by M'));
        expect(st.current!.lamp, Lamp.disconnected);
        expect(st.current!.takenOver, true);
        expect(st.needCount, 1);
        expect(st.needs.single.reconnectWord, '拿回来');
        final opens = t.sent.where((m) => m['cmd'] == 'open').length;
        final hint = st.hint;
        a.elapse(const Duration(seconds: 10));
        expect(t.sent.where((m) => m['cmd'] == 'open').length, opens);
        expect(st.hint, hint);
        expect(st.current!.lamp, Lamp.disconnected);
      });
    });

    test('opening an embedded app that is open switches to it without a second open', () {
      env((a, t, port, st, hints) {
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(t.sent.where((m) => m['cmd'] == 'open').length, 1);
        expect(st.hint, '已切到 Calculator');
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

    test('the host quitting the app reads 远端关闭了 app', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'host says: Calculator quit'));
        expect(st.current!.reason, '远端关闭了 app');
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
        final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
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
        final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
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

    test('a never-live disconnected record can be ended: row and need go', () {
      fakeAsync((a) {
        final t = FakeTransport();
        final port = FakeSessionPort();
        final st = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'offline', 'req': m['req']});
        };
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(st.needCount, 1);
        st.endCurrent();
        expect(st.sessionCount, 0);
        expect(st.recordFor('111/a'), isNull);
        expect(st.needCount, 0);
        expect(st.hint, '已结束 Calculator');
      });
    });

    test('ending a first connect (no old frame) takes the record; a late answer brings nothing back', () {
      for (final answer in ['error', 'opened']) {
        fakeAsync((a) {
          final t = FakeTransport();
          final port = FakeSessionPort();
          final st = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
          t.onSend = (_) {}; // the open never answers until we say so
          st.openOrSwitch('111', 'a', 'Calculator');
          a.flushMicrotasks();
          final req = t.sent.last['req'];
          expect(st.recordFor('111/a')!.phase, Phase.connecting);
          st.endCurrent();
          expect(st.sessionCount, 0, reason: answer);
          expect(st.hint, '已结束 Calculator');
          t.emit(answer == 'error' ? {'event': 'error', 'error': 'offline', 'req': req} : embedOpened(1, req));
          a.flushMicrotasks();
          a.elapse(const Duration(seconds: 2));
          expect(st.sessionCount, 0, reason: answer);
          expect(st.needCount, 0, reason: answer);
          expect(port.calls.where((c) => c.$1 == 'start'), isEmpty, reason: answer);
          if (answer == 'opened') expect(t.sent.last, {'cmd': 'close', 'sid': 1});
          expect(st.hint, '已结束 Calculator', reason: answer);
        });
      }
    });

    test('ended while the first start is in flight, a start failure does not bring it back (M-6)', () {
      fakeAsync((a) {
        final t = FakeTransport();
        final port = _SlowStartPort();
        final st = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit(embedOpened(1, m['req']));
        };
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        st.endCurrent();
        port.release('boom');
        a.flushMicrotasks();
        a.elapse(const Duration(seconds: 2));
        expect(st.sessionCount, 0);
        expect(st.recordFor('111/a'), isNull);
        expect(st.needCount, 0);
        expect(st.remote.containsKey(1), false);
        expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 1), isNotEmpty);
        expect(st.hint, isNot(contains('已断开')));
      });
    });

    group('overview', () {
      test('overview drops the current session to 1 fps', () {
        env((a, t, port, st, hints) {
          st.remote[2]!.setChoice(const StreamChoice('color16', 'adaptive', 30));
          expect(sets(port, 2).last['fps'], 30);
          final n1 = sets(port, 1).length;
          st.toggleOverview();
          expect(st.overview, true);
          expect(sets(port, 2).last['fps'], 1);
          expect(sets(port, 2).last['mode'], 'color16');
          expect(sets(port, 1).length, n1);
        }, sessions: 2);
      });

      test('a detached session keeps its rate in overview', () {
        env((a, t, port, st, hints) {
          port.emit(const DetachedEvent(2, true));
          final n = sets(port, 2).length;
          st.toggleOverview();
          expect(sets(port, 2).length, n);
          expect(sets(port, 2).isEmpty ? 15 : sets(port, 2).last['fps'], 15);
        }, sessions: 2);
      });

      test('leaving overview restores the current rate', () {
        env((a, t, port, st, hints) {
          st.remote[2]!.setChoice(const StreamChoice('color16', 'adaptive', 30));
          st.toggleOverview();
          expect(sets(port, 2).last['fps'], 1);
          st.toggleOverview();
          expect(st.overview, false);
          expect(sets(port, 2).last['fps'], 30);
          final n = sets(port, 2).length;
          st.togglePanel();
          expect(sets(port, 2).length, n);
        }, sessions: 2);
      });

      test('entering overview blurs the picture', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(2, [rw(7)]));
          st.focusPicture(2);
          expect(st.pictureFocused, 2);
          st.toggleOverview();
          expect(st.pictureFocused, isNull);
          final pf = port.calls.where((c) => c.$1 == 'picture_focus').last;
          expect(pf.$2['sid'], isNull);
          st.focusPicture(2);
          expect(st.pictureFocused, isNull);
        }, sessions: 2);
      });

      test('select leaves overview', () {
        env((a, t, port, st, hints) {
          st.toggleOverview();
          st.select('111/a');
          expect(st.overview, false);
          expect(st.currentKey, '111/a');
        }, sessions: 2);
      });

      test('opening with select leaves overview', () {
        env((a, t, port, st, hints) {
          st.toggleOverview();
          st.openOrSwitch('111', 'a', 'Calculator');
          a.flushMicrotasks();
          expect(st.overview, false);
          expect(st.currentKey, '111/a');
          st.toggleOverview();
          st.openOrSwitch('111', 'aaa', 'Third');
          a.flushMicrotasks();
          expect(st.overview, false);
          expect(st.currentKey, '111/aaa');
        }, sessions: 2);
      });

      test('showProject opens the projects tab and keeps overview', () {
        env((a, t, port, st, hints) {
          st.toggleOverview();
          st.showProject('p1');
          expect(st.panel, PanelTab.projects);
          expect(st.focusProject, 'p1');
          expect(st.overview, true);
        }, sessions: 1);
      });

      test('step stays in overview', () {
        env((a, t, port, st, hints) {
          st.toggleOverview();
          final before = st.currentKey;
          st.step(1);
          expect(st.overview, true);
          expect(st.currentKey, isNot(before));
        }, sessions: 2);
      });

      test('panels and corners keep overview', () {
        env((a, t, port, st, hints) {
          st.toggleOverview();
          st.togglePanel();
          expect(st.overview, true);
          st.showPanel(PanelTab.devices);
          expect(st.overview, true);
          st.toggleCorner(Corner.needs);
          expect(st.overview, true);
          st.showDevice('111');
          expect(st.overview, true);
        }, sessions: 2);
      });

      test('showCorner opens and stays', () {
        env((a, t, port, st, hints) {
          st.showCorner(Corner.needs);
          expect(st.corner, Corner.needs);
          st.showCorner(Corner.needs);
          expect(st.corner, Corner.needs);
        });
      });

      test('windowsOf counts the session\'s tabs', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(1, [rw(3), rw(7)]));
          expect(st.windowsOf('111/a'), 2);
          expect(st.windowsOf('111/nope'), 0);
        });
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
        final st = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
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
        final st = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
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
        port.emit(const TransferStatusEvent(1, '下载 x 45%'));
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

    void quietAfter(FakeAsync a, FakeTransport t, FakeSessionPort port, MainState st) {
      final sent = t.sent.length, calls = port.calls.length;
      st.focusPicture(1);
      st.stageSize(const Size(800, 600));
      st.selectWindow(7);
      st.detach();
      st.toggleDetach();
      a.elapse(const Duration(seconds: 1));
      final extra = port.calls.skip(calls).map((c) => c.$1).toList();
      expect(extra, isEmpty);
      expect(t.sent.length, sent);
    }

    test('a disconnected record sends nothing to the runner or the hub (R12)', () {
      env((a, t, port, st, hints) {
        port.emit(const ReadyEvent(1, 'Calculator'));
        port.emit(WindowsEvent(1, [rw(3), rw(7)]));
        port.emit(const TrafficEvent(1, 100, 1));
        st.stageSize(const Size(500, 400));
        a.elapse(const Duration(seconds: 1));
        port.emit(const DisconnectedEvent(1, 'user'));
        quietAfter(a, t, port, st);
      });
    });

    test('a reconnecting record sends nothing to the runner or the hub (R12)', () {
      env((a, t, port, st, hints) {
        port.emit(const ReadyEvent(1, 'Calculator'));
        port.emit(WindowsEvent(1, [rw(3), rw(7)]));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        t.onSend = (_) {}; // the reopen never answers: the record stays connecting
        st.reconnectCurrent();
        a.flushMicrotasks();
        expect(st.currentRecord!.phase, Phase.connecting);
        quietAfter(a, t, port, st);
      });
    });

    test('reconnect opened but not swapped sends nothing to the old sid (R12)', () {
      env((a, t, port, st, hints) {
        port.emit(const ReadyEvent(1, 'Calculator'));
        port.emit(WindowsEvent(1, [rw(3), rw(7)]));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnectCurrent();
        a.flushMicrotasks(); // the hub answers `opened` (sid 11); no textured window yet
        expect(st.currentRecord!.phase, Phase.live);
        expect(st.currentRecord!.lastSid, 1);
        expect(st.canToggleDetach, false);
        quietAfter(a, t, port, st);
      });
    });

    test('a sid no record claims is not heard (fails closed)', () {
      env((a, t, port, st, hints) {
        final calls = port.calls.length;
        st.focusPicture(999);
        expect(port.calls.length, calls);
        expect(st.pictureFocused, isNull);
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

    // ---- 全部打开 / 全部结束 (S5 K11–K13) ----
    void devices(FakeAsync a, FakeTransport t) {
      t.emit({
        'event': 'hosts',
        'hosts': [
          {'id': '111', 'name': 'mini'},
          {'id': '222', 'name': 'studio'},
        ],
      });
      a.flushMicrotasks();
    }

    Project project(MainState st, String name, List<String> keys) {
      final p = st.createProject(name)!;
      for (final k in keys) {
        final [d, b] = k.split('/');
        st.addMember(p.id, AppRef(d, b, b.toUpperCase()));
      }
      return p;
    }

    List<Map<String, dynamic>> openCmds(FakeTransport t) => [for (final m in t.sent) if (m['cmd'] == 'open') m];

    test('open all mixes open, reconnect, skip and stop', () {
      env((a, t, port, st, hints) {
        devices(a, t);
        st.probes['222'] = DeviceProbe(Lamp.offline, '离线');
        final p = project(st, '写周报', ['111/a', '111/aa', '222/aaa', '111/aaaa']);
        st.openOrSwitch('111', 'a', 'A');
        a.flushMicrotasks();
        st.openOrSwitch('111', 'aa', 'AA');
        a.flushMicrotasks();
        port.emit(const DisconnectedEvent(2, 'connection closed'));
        st.togglePanel(PanelTab.projects);
        final before = openCmds(t).length;
        hints.clear();
        st.openAll(p.id);
        a.flushMicrotasks();
        final sent = openCmds(t).skip(before).toList();
        expect(sent.map((m) => m['app']), ['aa', 'aaaa']);
        expect(sent[0]['reconnect'], true);
        expect(sent[1].containsKey('reconnect'), false);
        expect(st.recordFor('111/aaaa')!.phase, Phase.live);
        expect(st.entryFor('222/aaa'), isNull);
        expect(st.currentKey, '111/a');
        expect(st.panel, isNull);
        expect(hints.last, '写周报：打开 2 个；studio 离线，跳过 1 个');
        expect(hints.where((h) => h.startsWith('已打开')), isEmpty);
        // The skipped device is only in the hint, not something waiting for the person.
        expect(st.needs.where((n) => n.kind == NeedKind.device), isEmpty);
      }, sessions: 0);
    });

    test('openAll leaves overview', () {
      env((a, t, port, st, hints) {
        devices(a, t);
        final p = project(st, '写周报', ['111/a', '111/aa']);
        st.toggleOverview();
        st.openAll(p.id);
        a.flushMicrotasks();
        expect(st.overview, false);
        expect(st.currentKey, '111/a');
      }, sessions: 0);
    });

    test('open all twice sends each open once', () {
      env((a, t, port, st, hints) {
        devices(a, t);
        t.onSend = null; // the hub never answers: both stay connecting
        final p = project(st, '写周报', ['111/a', '111/aa']);
        st.openAll(p.id);
        a.flushMicrotasks();
        st.openAll(p.id);
        a.flushMicrotasks();
        expect(openCmds(t), hasLength(2));
        expect(st.hint, '写周报：已经全部打开');
        expect(st.currentKey, '111/a');
      }, sessions: 0);
    });

    test('open all stops on the first member even when its open fails', () {
      env((a, t, port, st, hints) {
        devices(a, t);
        final answer = t.onSend!;
        t.onSend = (m) {
          if (m['cmd'] == 'open' && m['app'] == 'a') {
            t.emit({'event': 'error', 'error': 'unreachable', 'req': m['req']});
          } else {
            answer(m);
          }
        };
        final p = project(st, '写周报', ['111/a', '111/aa']);
        st.openAll(p.id);
        a.flushMicrotasks();
        expect(st.currentKey, '111/a');
        expect(st.entryFor('111/a')!.lamp, Lamp.disconnected);
        expect(st.recordFor('111/aa')!.phase, Phase.live);
        expect(hints.first, '写周报：打开 2 个');
        expect(st.hint, startsWith('A 已断开：'));
      }, sessions: 0);
    });

    test('a disconnected member shows its reason', () {
      env((a, t, port, st, hints) {
        final m = Member(const AppRef('111', 'a', 'Calculator'));
        port.emit(const DisconnectedEvent(1, 'the host closed the connection'));
        expect(st.memberLamp(m), Lamp.disconnected);
        expect(st.memberStatus(m), '已断开：网络断了');
      });
    });

    test('end all hint survives late closed events', () {
      env((a, t, port, st, hints) {
        final p = project(st, '写周报', ['111/a', '111/aa']);
        st.endAll(p.id);
        expect(port.calls.where((c) => c.$1 == 'close').map((c) => c.$2['sid']), [1, 2]);
        expect(hints.last, '写周报：结束 2 个会话');
        expect(hints.where((h) => h.startsWith('正在结束')), isEmpty);
        port.emit(const ClosedEvent(1, 'stdin closed'));
        port.emit(const ClosedEvent(2, 'stdin closed'));
        a.flushMicrotasks();
        expect(st.hint, '写周报：结束 2 个会话');
        expect(st.entryFor('111/a'), isNull);
        expect(st.entryFor('111/aa'), isNull);
      }, sessions: 2);
    });

    test('end all counts sessions shared with another project', () {
      env((a, t, port, st, hints) {
        final pa = project(st, 'A', ['111/a', '111/aa']);
        final pb = project(st, 'B', ['111/a']);
        st.endAll(pa.id);
        expect(st.hint, 'A：结束 2 个会话，其中 1 个也属于别的项目');
        port.emit(const ClosedEvent(1, 'stdin closed'));
        port.emit(const ClosedEvent(2, 'stdin closed'));
        a.flushMicrotasks();
        expect(st.entryFor(pb.members.single.key), isNull);
        expect(st.memberLamp(pb.members.single), Lamp.notOpened);
        expect(st.hint, 'A：结束 2 个会话，其中 1 个也属于别的项目');
      }, sessions: 2);
    });

    test('end all ends connecting and disconnected members at once', () {
      env((a, t, port, st, hints) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        final answer = t.onSend!;
        final held = <Map<String, dynamic>>[];
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            held.add(m);
          } else {
            answer(m);
          }
        };
        st.openOrSwitch('111', 'aa', 'Notes');
        a.flushMicrotasks();
        expect(st.entryFor('111/aa')!.lamp, Lamp.connecting);
        final p = project(st, '写周报', ['111/a', '111/aa']);
        st.endAll(p.id);
        expect(st.entryFor('111/a'), isNull);
        expect(st.entryFor('111/aa'), isNull);
        expect(closes(port, 1), hasLength(1));
        expect(st.hint, '写周报：结束 2 个会话');
        answer(held.single);
        a.flushMicrotasks();
        expect(t.sent.last, {'cmd': 'close', 'sid': 2});
        expect(port.calls.where((c) => c.$1 == 'start' && c.$2['sid'] == 2), isEmpty);
        expect(st.entryFor('111/aa'), isNull);
        expect(st.hint, '写周报：结束 2 个会话');
      });
    });

    // S5-5b: an end the user asked for is finished by the link going away, not turned into 已断开.
    test('an ended session whose link drops first is gone and opens again normally', () {
      env((a, t, port, st, hints) {
        expect(st.endSession('111/a'), isTrue);
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        expect(st.entryFor('111/a'), isNull);
        expect(st.needCount, 0);
        expect(st.hint, '已结束 Calculator');
        port.emit(const ClosedEvent(1, 'stdin closed')); // late: nothing left to end
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(st.recordFor('111/a')!.phase, Phase.live);
        port.emit(const TrafficEvent(1, 5000, 2));
        expect(st.entryFor('111/a')!.lamp, Lamp.active);
      });
    });

    test('an ended session whose hub session closes first is gone after 1 s and opens again', () {
      env((a, t, port, st, hints) {
        expect(st.endSession('111/a'), isTrue);
        t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
        a.flushMicrotasks();
        a.elapse(const Duration(seconds: 1));
        expect(st.entryFor('111/a'), isNull);
        expect(st.needCount, 0);
        expect(st.hint, '已结束 Calculator');
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(st.recordFor('111/a')!.phase, Phase.live);
        port.emit(const TrafficEvent(1, 5000, 2));
        expect(st.entryFor('111/a')!.lamp, Lamp.active);
      });
    });

    test('end all then a link drop keeps the summary and forgets the batch', () {
      env((a, t, port, st, hints) {
        final p = project(st, '写周报', ['111/a', '111/aa']);
        st.endAll(p.id);
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        t.emit({'event': 'closed', 'sid': 2, 'reason': 'connection closed'});
        a.flushMicrotasks();
        a.elapse(const Duration(seconds: 1));
        expect(st.entryFor('111/a'), isNull);
        expect(st.entryFor('111/aa'), isNull);
        expect(st.hint, '写周报：结束 2 个会话');
        // Nothing stale in the batch: a later end of the same key says so again.
        st.reconnect('111/a'); // no record: does nothing
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        st.endCurrent();
        port.emit(const ClosedEvent(1, 'stdin closed'));
        expect(st.hint, '已结束 Calculator');
      }, sessions: 2);
    });

    test('reopening after end all hints normally', () {
      env((a, t, port, st, hints) {
        final p = project(st, '写周报', ['111/a']);
        st.endAll(p.id);
        port.emit(const ClosedEvent(1, 'stdin closed'));
        a.flushMicrotasks();
        expect(st.hint, '写周报：结束 1 个会话');
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        expect(st.hint, '已打开 Calculator @ 111');
        st.endCurrent();
        expect(st.hint, '正在结束 Calculator');
        port.emit(const ClosedEvent(1, 'stdin closed'));
        a.flushMicrotasks();
        expect(st.hint, '已结束 Calculator');
      });
    });

    group('moving to a new route', () {
      // [sessions] live sessions on 111 (`a`, `aa`, … with sids 1, 2, …) over [on], each with a picture.
      // Reopens (`reconnect: true`) wait in `reopens` until the test answers them.
      void move(
          void Function(FakeAsync a, FakeTransport t, FakeSessionPort port, MainState st, List<String> hints,
                  List<Map<String, dynamic>> reopens)
              body,
          {String on = 'relay',
          int sessions = 2}) {
        fakeAsync((a) {
          final t = FakeTransport();
          final port = FakeSessionPort();
          final st = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
          final reopens = <Map<String, dynamic>>[];
          t.onSend = (m) {
            if (m['cmd'] != 'open') return;
            if (m['reconnect'] == true) {
              reopens.add(m);
              return;
            }
            final n = (m['app'] as String).length;
            t.emit({...embedOpened(n, m['req'], app: m['app'] as String), 'path': on});
          };
          for (var i = 1; i <= sessions; i++) {
            st.openOrSwitch('111', 'a' * i, 'App$i');
            a.flushMicrotasks();
            port.emit(WindowsEvent(i, [rw(3)]));
          }
          final hints = <String>[];
          st.addListener(() {
            if (st.hint.isNotEmpty && (hints.isEmpty || hints.last != st.hint)) hints.add(st.hint);
          });
          st.hint = '';
          body(a, t, port, st, hints, reopens);
        });
      }

      void path(FakeAsync a, FakeTransport t, String p) {
        t.emit({'event': 'path', 'id': '111', 'path': p});
        a.flushMicrotasks();
      }

      void answer(FakeAsync a, FakeTransport t, Map<String, dynamic> open, int sid, String p) {
        t.emit({...embedOpened(sid, open['req'], app: open['app'] as String), 'path': p});
        a.flushMicrotasks();
      }

      void picture(FakeAsync a, FakeSessionPort port, int sid) {
        port.emit(WindowsEvent(sid, [rw(3)]));
        a.flushMicrotasks();
      }

      bool routeFailed(FakeTransport t) => t.sent.any((m) => m['cmd'] == 'route_failed' && m['id'] == '111');

      test('a path change reopens each live session once, one at a time', () {
        move((a, t, port, st, hints, reopens) {
          final before = t.sent.where((m) => m['cmd'] == 'open').length;
          path(a, t, 'lan');
          expect(reopens.length, 1);
          expect(reopens[0]['app'], 'a');
          expect(reopens[0]['reconnect'], true);
          expect(reopens[0]['embed'], true);
          answer(a, t, reopens[0], 11, 'lan');
          expect(reopens.length, 1, reason: 'the second waits for the first to show a picture');
          expect(st.recordFor('111/a')!.phase, Phase.live);
          picture(a, port, 11);
          expect(reopens.length, 2);
          expect(reopens[1]['app'], 'aa');
          answer(a, t, reopens[1], 12, 'lan');
          picture(a, port, 12);
          expect(t.sent.where((m) => m['cmd'] == 'open').length, before + 2);
          expect(st.recordFor('111/a')!.path, 'lan');
          expect(st.recordFor('111/aa')!.path, 'lan');
          expect(st.recordFor('111/a')!.sid, 11);
          expect(st.recordFor('111/aa')!.sid, 12);
          expect(closes(port, 1), isNotEmpty);
          expect(closes(port, 2), isNotEmpty);
          expect(hints, isEmpty);
          expect(routeFailed(t), false);
          a.elapse(const Duration(seconds: 20));
          expect(reopens.length, 2);
        });
      });

      test('sessions already on the new path are left alone', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          a.elapse(const Duration(seconds: 1));
          expect(reopens, isEmpty);
          expect(st.recordFor('111/a')!.sid, 1);
        }, on: 'lan');
      });

      test('a failed reopen stays on its route and tells the hub', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          t.emit({'event': 'error', 'error': 'offline', 'req': reopens[0]['req']});
          a.flushMicrotasks();
          final r = st.recordFor('111/a')!;
          expect(r.sid, 1);
          expect(r.lastSid, isNull);
          expect(r.phase, Phase.live);
          expect(r.path, 'relay');
          expect(st.currentRemote, isNotNull);
          expect(st.hint, isEmpty);
          expect(hints, isEmpty);
          expect(routeFailed(t), true);
          a.elapse(const Duration(seconds: 20));
          expect(reopens.length, 1, reason: 'the rest of the round stays where it is');
          expect(st.recordFor('111/aa')!.sid, 2);
        });
      });

      test('a failed start of the reopen also stays on its route', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          port.startError = 'boom';
          answer(a, t, reopens[0], 11, 'lan');
          final r = st.recordFor('111/a')!;
          expect(r.sid, 1);
          expect(r.phase, Phase.live);
          expect(r.path, 'relay');
          expect(st.remote.containsKey(11), false);
          expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 11), isNotEmpty);
          expect(hints, isEmpty);
          expect(routeFailed(t), true);
        });
      });

      test('a reopen that never shows a picture times out', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          a.elapse(const Duration(seconds: 14));
          expect(closes(port, 11), isEmpty);
          expect(routeFailed(t), false);
          a.elapse(const Duration(seconds: 1));
          expect(closes(port, 11), isNotEmpty);
          expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 11), isNotEmpty);
          expect(closes(port, 1), isEmpty);
          final r = st.recordFor('111/a')!;
          expect(r.sid, 1);
          expect(r.lastSid, isNull);
          expect(r.phase, Phase.live);
          expect(r.path, 'relay');
          expect(st.remote.containsKey(11), false);
          expect(routeFailed(t), true);
          expect(reopens.length, 1);
          // A late picture of the dropped session changes nothing.
          picture(a, port, 11);
          expect(st.recordFor('111/a')!.sid, 1);
          // The hub's `closed` for the dropped sid is not news.
          t.emit({'event': 'closed', 'sid': 11, 'reason': 'connection closed'});
          a.flushMicrotasks();
          a.elapse(const Duration(seconds: 2));
          expect(hints, isEmpty);
          expect(st.recordFor('111/a')!.phase, Phase.live);
        });
      });

      test('a second path change during a move stops the round; the next one goes by the latest', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          expect(reopens.length, 1);
          path(a, t, 'relay'); // forced onto the relay while the first one moves
          expect(reopens.length, 1, reason: 'one round per host at a time');
          answer(a, t, reopens[0], 11, 'lan');
          picture(a, port, 11);
          expect(st.recordFor('111/a')!.path, 'lan');
          expect(reopens.length, 2, reason: 'the next round, toward relay, right away');
          expect(reopens[1]['app'], 'a', reason: 'aa is not reopened toward the old path');
          answer(a, t, reopens[1], 12, 'relay');
          picture(a, port, 12);
          a.elapse(const Duration(seconds: 20));
          expect(reopens.length, 2, reason: 'aa is on the relay already');
          expect(st.recordFor('111/a')!.path, 'relay');
          expect(st.recordFor('111/aa')!.path, 'relay');
          expect(st.recordFor('111/aa')!.sid, 2);
          expect(routeFailed(t), false);
          expect(hints, isEmpty);
        });
      });

      test('a session with no picture is skipped, not failed: the one after it still moves', () {
        move((a, t, port, st, hints, reopens) {
          port.emit(const WindowsEvent(1, [])); // minimised: no window to show
          a.flushMicrotasks();
          path(a, t, 'lan');
          expect(reopens.length, 1);
          expect(reopens[0]['app'], 'aa');
          answer(a, t, reopens[0], 12, 'lan');
          picture(a, port, 12);
          expect(st.recordFor('111/aa')!.path, 'lan');
          a.elapse(const Duration(seconds: 20));
          expect(reopens.length, 1);
          final r = st.recordFor('111/a')!;
          expect((r.sid, r.path, r.phase), (1, 'relay', Phase.live));
          expect(routeFailed(t), false);
          expect(hints, isEmpty);
        });
      });

      test('ending a session mid-move does not bring it back', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          st.endSession('111/aa');
          port.emit(const ClosedEvent(2, 'stdin closed'));
          a.flushMicrotasks();
          answer(a, t, reopens[0], 11, 'lan');
          picture(a, port, 11);
          a.elapse(const Duration(seconds: 20));
          expect(reopens.length, 1);
          expect(st.recordFor('111/aa'), isNull);
          expect(st.entries.map((e) => e.key), ['111/a']);
          expect(routeFailed(t), false);
        });
      });

      test('ending the session being moved ends both sessions and the round goes on', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          st.endSession('111/a');
          a.flushMicrotasks();
          expect(reopens.length, 2, reason: 'the next session still moves');
          expect(reopens[1]['app'], 'aa');
          answer(a, t, reopens[1], 12, 'lan');
          picture(a, port, 12);
          expect(routeFailed(t), false);
          a.elapse(const Duration(seconds: 16)); // the runner is slow to say so: past the move's time
          expect(closes(port, 1), isEmpty, reason: 'still ending: the old one goes with the new one');
          expect(closes(port, 11).length, 1);
          port.emit(const ClosedEvent(11, 'stdin closed'));
          a.flushMicrotasks();
          expect(st.recordFor('111/a'), isNull);
          expect(closes(port, 1).length, 1);
          expect(closes(port, 11).length, 1);
          expect(st.remote.containsKey(1), false);
          expect(st.remote.containsKey(11), false);
          expect(routeFailed(t), false);
          a.elapse(const Duration(seconds: 20));
          expect(st.recordFor('111/a'), isNull);
        });
      });

      test('ending the session while its reopen is in flight closes the new one quietly', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          st.endSession('111/a');
          port.emit(const ClosedEvent(1, 'stdin closed'));
          a.flushMicrotasks();
          expect(st.recordFor('111/a'), isNull);
          answer(a, t, reopens[0], 11, 'lan');
          expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 11), isNotEmpty);
          expect(port.calls.where((c) => c.$1 == 'start' && c.$2['sid'] == 11), isEmpty);
          expect(st.recordFor('111/a'), isNull);
          expect(reopens.length, 2);
          expect(routeFailed(t), false);
        });
      });

      test('disconnecting the session being moved leaves one disconnected session', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          st.select('111/a');
          st.disconnectCurrent();
          expect(t.sent.last, {'cmd': 'close', 'sid': 1, 'reason': 'user'});
          expect(closes(port, 11), isNotEmpty);
          expect(st.remote.containsKey(11), false);
          t.emit({'event': 'closed', 'sid': 1, 'reason': 'user'});
          port.emit(const DisconnectedEvent(1, 'user'));
          a.flushMicrotasks();
          final r = st.recordFor('111/a')!;
          expect(r.phase, Phase.disconnected);
          expect(r.sid, 1);
          expect(r.lastSid, isNull);
          expect(routeFailed(t), false);
          expect(reopens.length, 2, reason: 'the next session still moves');
        });
      });

      test('forcing relay moves sessions to the relay', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'relay');
          expect(reopens.length, 1);
          answer(a, t, reopens[0], 11, 'relay');
          picture(a, port, 11);
          expect(st.recordFor('111/a')!.path, 'relay');
          expect(reopens.length, 2);
          t.emit({'event': 'error', 'error': 'relay unreachable: x', 'req': reopens[1]['req']});
          a.flushMicrotasks();
          expect(st.recordFor('111/aa')!.path, 'lan');
          expect(st.recordFor('111/aa')!.phase, Phase.live);
          expect(routeFailed(t), false);
          expect(hints, isEmpty);
        }, on: 'lan');
      });

      test('mid-move the old session keeps the stage, its windows and the keys; the focus follows the swap', () {
        move((a, t, port, st, hints, reopens) {
          st.select('111/a');
          st.focusPicture(1);
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          expect(st.pictureFocused, 1);
          expect(st.currentRemote!.sid, 1);
          port.emit(WindowsEvent(1, [rw(3), rw(7)]));
          a.flushMicrotasks();
          expect(st.remote[1]!.windows.length, 2);
          st.selectWindow(7);
          expect(port.calls.last.$1, 'select_window');
          expect(port.calls.last.$2, {'sid': 1, 'window': 7});
          picture(a, port, 11);
          expect(st.currentRemote!.sid, 11);
          expect(st.pictureFocused, 11);
          expect(port.calls.where((c) => c.$1 == 'picture_focus').last.$2, {'sid': 11});
        });
      });

      test('a session detached before the move is still detached after the swap', () {
        move((a, t, port, st, hints, reopens) {
          st.select('111/a');
          port.emit(const DetachedEvent(1, true));
          a.flushMicrotasks();
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          picture(a, port, 11);
          expect(st.recordFor('111/a')!.sid, 11);
          expect(port.calls.where((c) => c.$1 == 'detach').last.$2, {'sid': 11});
          port.emit(const DetachedEvent(11, true));
          a.flushMicrotasks();
          expect(st.currentRemote!.detached, true);
        });
      });

      test('a detach made mid-move is told to the hub and survives the swap', () {
        move((a, t, port, st, hints, reopens) {
          st.select('111/a');
          st.focusPicture(1);
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          st.detach();
          expect(port.calls.last.$1, 'detach');
          expect(port.calls.last.$2, {'sid': 1});
          port.emit(const DetachedEvent(1, true));
          a.flushMicrotasks();
          expect(t.sent.any((m) => m['cmd'] == 'note' && m['sid'] == 1 && m['what'] == 'detach'), true);
          expect(st.pictureFocused, isNull);
          picture(a, port, 11);
          expect(port.calls.where((c) => c.$1 == 'detach').last.$2, {'sid': 11});
          expect(st.pictureFocused, isNull, reason: 'no keys go to a detached session');
        });
      });

      test('an attached session is not detached by the move', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          picture(a, port, 11);
          expect(port.calls.where((c) => c.$1 == 'detach'), isEmpty);
        });
      });

      test('clips and transfers of the old session mid-move reach the resources; what runs at the swap ends 没传完',
          () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          port.emit(const ClipsEvent(1, [ClipRow(1, 'mid', true)]));
          port.emit(const TransferProgressEvent(1, 5, true, 'a.log', 10, 100, TransferState.running, null, null));
          a.flushMicrotasks();
          expect(st.resources.clips.map((e) => e.title), ['mid']);
          expect(st.resources.running.single.name, 'a.log');
          picture(a, port, 11);
          expect(st.resources.running, isEmpty);
          final row = st.resources.ended.single;
          expect(row.state, TransferState.failed);
          expect(row.error, '没传完');
        });
      });

      test('a transfer of the old session ends 没传完 when the runner closes it mid-move', () {
        move((a, t, port, st, hints, reopens) {
          port.emit(const TransferProgressEvent(1, 5, true, 'a.log', 10, 100, TransferState.running, null, null));
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          port.emit(const ClosedEvent(1, 'rapp-client: quit'));
          a.flushMicrotasks();
          expect(st.resources.running, isEmpty);
          expect(st.resources.ended.single.error, '没传完');
          expect(st.recordFor('111/a')!.sid, 11);
        });
      });

      test('the old session gone during a move that then fails: the record is down, not revived elsewhere', () {
        move((a, t, port, st, hints, reopens) {
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          t.emit({'event': 'closed', 'sid': 1, 'reason': 'connection closed'});
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.flushMicrotasks();
          a.elapse(const Duration(seconds: 15));
          final r = st.recordFor('111/a')!;
          expect(r.phase, Phase.disconnected);
          expect(r.sid, 1);
          expect(r.lastSid, isNull);
          expect(st.remote.containsKey(11), false);
          expect(closes(port, 11), isNotEmpty);
          expect(routeFailed(t), false, reason: 'the LAN did not fail: the session went');
          expect(reopens.length, 2);
        });
      });

      test('another host\'s path change moves nothing here', () {
        move((a, t, port, st, hints, reopens) {
          t.emit({'event': 'path', 'id': '222', 'path': 'lan'});
          a.flushMicrotasks();
          expect(reopens, isEmpty);
        });
      });
    });
  });

  group('needs', () {
    void env(void Function(FakeAsync a, FakeTransport t, FakeSessionPort port, MainState st) body) {
      fakeAsync((a) {
        final t = FakeTransport();
        final hub = HubClient(t);
        final port = FakeSessionPort();
        t.emit({
          'event': 'hosts',
          'hosts': [
            {'id': '111', 'name': 'mini'},
            {'id': '222', 'name': ''},
          ],
        });
        a.flushMicrotasks();
        final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': m['reconnect'] == true ? 2 : 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              if (m['embed'] == true) ...{'port': 5001, 'token': 'tk'},
              'req': m['req'],
            });
          }
        };
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        body(a, t, port, st);
        st.dispose();
      });
    }

    void presence(FakeAsync a, FakeTransport t, String id, bool online) {
      t.emit({'event': 'presence', 'id': id, 'online': online});
      a.flushMicrotasks();
    }

    test('disconnects and dropped devices count, newest first', () {
      env((a, t, port, st) {
        expect(st.needCount, 0);
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        presence(a, t, '111', true);
        presence(a, t, '111', false);
        expect(st.needCount, 2);
        expect(st.needs.first.kind, NeedKind.device);
        expect(st.needs.first.text, 'mini 离线');
        expect(st.needs.first.target, '111');
        expect(st.needs.last.kind, NeedKind.session);
        expect(st.needs.last.target, '111/a');
        expect(st.needs.last.text, 'Calculator @ mini 已断开：网络断了');
      });
    });

    test('a device never seen online is not counted', () {
      env((a, t, port, st) {
        presence(a, t, '222', false);
        expect(st.needCount, 0);
        expect(st.probes['222']!.lamp, Lamp.offline);
      });
    });

    test('a manual probe does not flicker the needs count', () {
      env((a, t, port, st) {
        presence(a, t, '111', true);
        presence(a, t, '111', false);
        expect(st.needCount, 1);
        st.probe('111');
        a.flushMicrotasks();
        final req = t.sent.last['req'];
        expect(t.sent.last['cmd'], 'apps');
        expect(st.probes['111']!.lamp, Lamp.connecting);
        expect(st.needCount, 1);
        t.emit({'event': 'error', 'req': req, 'error': 'unreachable'});
        a.flushMicrotasks();
        expect(st.probes['111']!.lamp, Lamp.offline);
        expect(st.needCount, 1);
        st.probe('111');
        a.flushMicrotasks();
        t.emit({'event': 'apps', 'req': t.sent.last['req'], 'id': '111', 'apps': []});
        a.flushMicrotasks();
        expect(st.probes['111']!.lamp, Lamp.active);
        expect(st.needCount, 0);
      });
    });

    test('presence skips a probe in flight', () {
      env((a, t, port, st) {
        st.probe('111');
        a.flushMicrotasks();
        final req = t.sent.last['req'];
        presence(a, t, '111', false);
        expect(st.probes['111']!.lamp, Lamp.connecting);
        t.emit({'event': 'apps', 'req': req, 'id': '111', 'apps': []});
        a.flushMicrotasks();
        expect(st.probes['111']!.lamp, Lamp.active);
        expect(st.needCount, 0);
      });
    });

    test('reconnecting and ending clear the need without a click', () {
      env((a, t, port, st) {
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        expect(st.needCount, 1);
        st.reconnect('111/a');
        a.flushMicrotasks();
        expect(st.needCount, 0);
        port.emit(const DisconnectedEvent(2, 'connection closed'));
        expect(st.needCount, 1);
        st.endCurrent();
        expect(st.needCount, 0);
      });
    });

    test('a removed device leaves the needs', () {
      env((a, t, port, st) {
        presence(a, t, '111', true);
        presence(a, t, '111', false);
        expect(st.needCount, 1);
        t.onSend = (m) {
          if (m['cmd'] == 'remove_host') t.emit({'event': 'hosts', 'req': m['req'], 'hosts': []});
        };
        st.removeDevice('111');
        a.flushMicrotasks();
        expect(st.needs.where((n) => n.kind == NeedKind.device), isEmpty);
      });
    });

    test('showDevice opens the device panel on it', () {
      env((a, t, port, st) {
        st.toggleCorner(Corner.needs);
        st.showDevice('111');
        a.flushMicrotasks();
        expect(st.panel, PanelTab.devices);
        expect(st.deviceTab, '111');
        expect(st.corner, isNull);
        expect(t.sent.last['cmd'], 'apps');
        expect(t.sent.last['id'], '111');
      });
    });

    test('corners are exclusive and the stream corner follows the session', () {
      env((a, t, port, st) {
        st.openOrSwitch('111', 'aa', 'Notes');
        a.flushMicrotasks();
        st.toggleCorner(Corner.stream);
        expect(st.corner, Corner.stream);
        st.toggleCorner(Corner.needs);
        expect(st.corner, Corner.needs);
        st.toggleCorner(Corner.needs);
        expect(st.corner, isNull);
        st.toggleCorner(Corner.stream);
        st.select('111/a');
        expect(st.corner, isNull);
        st.toggleCorner(Corner.needs);
        st.select('111/aa');
        expect(st.corner, Corner.needs);
        st.closeCorner();
        expect(st.corner, isNull);
      });
    });

    test('disconnects never open a corner or set a hint', () {
      env((a, t, port, st) {
        final hint = st.hint;
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        expect(st.corner, isNull);
        expect(st.hint, hint);
        presence(a, t, '111', true);
        presence(a, t, '111', false);
        expect(st.corner, isNull);
        expect(st.hint, hint);
      });
    });
  });

  group('projects', () {
    const notes = AppRef('111', 'com.apple.Notes', 'Notes');
    const key = '111/com.apple.Notes';

    test('create, rename and delete a project', () {
      expect(s.createProject('  '), isNull);
      expect(s.projects, isEmpty);
      final p = s.createProject('写\n周报')!;
      expect(p.name, '写 周报');
      s.renameProject(p.id, '');
      expect(s.projects.single.name, '写 周报');
      s.renameProject(p.id, '周报');
      expect(s.projects.single.name, '周报');
      s.deleteProject(p.id);
      expect(s.projects, isEmpty);
      expect(s.hint, '');
    });

    test('members are unique within a project but shared across projects', () {
      final a = s.createProject('A')!;
      final b = s.createProject('B')!;
      expect(s.addMember(a.id, notes), isTrue);
      expect(s.addMember(a.id, notes), isFalse);
      expect(s.addMember(b.id, notes), isTrue);
      expect(s.projectsOf(key).map((p) => p.name), ['A', 'B']);
      s.removeMember(a.id, key);
      expect(s.projectsOf(key).map((p) => p.name), ['B']);
      expect(s.hint, '');
    });

    test('tasks are one line and can be cleared', () {
      final a = s.createProject('A')!;
      s.addMember(a.id, notes);
      s.setTask(a.id, key, '整理\nPR');
      expect(a.members.single.task, '整理 PR');
      s.setTask(a.id, key, '');
      expect(a.members.single.task, '');
    });

    test('projects survive a restart', () {
      final a = s.createProject('A')!;
      s.addMember(a.id, notes);
      s.addMember(a.id, const AppRef('222', 'com.apple.Chess', 'Chess'));
      s.setTask(a.id, key, '整理');
      final s2 = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
      expect(s2.projects.single.name, 'A');
      expect(s2.projects.single.members.map((m) => m.key), [key, '222/com.apple.Chess']);
      expect(s2.projects.single.members.first.task, '整理');
    });

    test('deleting a project ends no session', () async {
      t.emit(opened(1, '111', 'com.apple.Notes'));
      await pump();
      final a = s.createProject('A')!;
      s.addMember(a.id, notes);
      s.deleteProject(a.id);
      expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
      expect(s.entryFor(key), isNotNull);
    });

    test('member lamp and status', () async {
      final m = Member(notes);
      final m2 = Member(const AppRef('222', 'com.apple.Chess', 'Chess'));
      expect(s.memberLamp(m), Lamp.notOpened);
      expect(s.memberStatus(m), '未打开');
      s.probes['222'] = DeviceProbe(Lamp.offline, '离线');
      expect(s.memberStatus(m2), '未打开，设备离线');
      expect(s.deviceOffline('222'), isTrue);
      expect(s.deviceOffline('999'), isTrue);
      t.emit(opened(1, '111', 'com.apple.Notes'));
      await pump();
      expect(s.memberLamp(m), Lamp.active);
      expect(s.memberStatus(m), '活动');
    });

    test('addable apps list online devices then favorites, minus members', () {
      s.probes['111'] = DeviceProbe(Lamp.active, '在线',
          apps: const AppList('111', 'lan', [HubApp('com.apple.Safari', 'Safari'), HubApp('com.apple.Notes', 'Notes')]));
      s.toggleFavorite('222', 'com.apple.Chess', 'Chess');
      s.toggleFavorite('111', 'com.apple.Notes', 'Notes');
      final a = s.createProject('A')!;
      s.addMember(a.id, const AppRef('111', 'com.apple.Safari', 'Safari'));
      expect(s.addableApps(a.id).map((x) => x.key), ['111/com.apple.Notes', '222/com.apple.Chess']);
    });

    test('removing a device keeps project members', () async {
      final a = s.createProject('A')!;
      s.addMember(a.id, const AppRef('222', 'com.apple.Chess', 'Chess'));
      t.onSend = (m) {
        if (m['cmd'] == 'remove_host') {
          t.emit({'event': 'hosts', 'req': m['req'], 'hosts': [{'id': '111', 'name': 'mini'}]});
        }
      };
      await s.removeDevice('222');
      expect(a.members, hasLength(1));
      expect(s.deviceOffline('222'), isTrue);
    });

    test('step walks project groups without sticking', () async {
      for (final (i, b) in ['com.a', 'com.b', 'com.c'].indexed) {
        t.emit(opened(i + 1, '111', b));
        await pump();
      }
      s.addMember(s.createProject('P1')!.id, const AppRef('111', 'com.b', 'b'));
      final p2 = s.createProject('P2')!;
      s.addMember(p2.id, const AppRef('111', 'com.a', 'a'));
      s.addMember(p2.id, const AppRef('111', 'com.b', 'b'));
      s.setGrouping(Grouping.project);
      s.select('111/com.b');
      final seen = <String?>[s.currentKey];
      for (var i = 0; i < 4; i++) {
        s.step(1);
        seen.add(s.currentKey);
      }
      expect(seen.take(4).toSet(), hasLength(3));
      expect(seen[3], seen[0]);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], isNot(seen[i - 1]));
      }
    });
  });

  group('resources', () {
    final t0 = DateTime(2026, 11, 12, 9, 30);

    void env(void Function(FakeAsync a, FakeTransport t, FakeSessionPort port, MainState st) body,
        {FakeSessionPort? usePort, void Function()? pre}) {
      fakeAsync((a) {
        pre?.call();
        final t = FakeTransport();
        final port = usePort ?? FakeSessionPort();
        t.emit({
          'event': 'hosts',
          'hosts': [
            {'id': '111', 'name': 'mini'},
            {'id': '222', 'name': 'air'},
          ],
        });
        a.flushMicrotasks();
        final st = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: port, clock: () => t0);
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            final n = (m['id'] == '111' ? 1 : 2) + (m['reconnect'] == true ? 10 : 0);
            t.emit({
              'event': 'opened', 'sid': n, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              if (m['embed'] == true) ...{'port': 5000 + n, 'token': 'tk'},
              'req': m['req'],
            });
          }
        };
        st.openOrSwitch('111', 'calc', 'Calculator');
        a.flushMicrotasks();
        body(a, t, port, st);
        st.dispose();
      });
    }

    void openNotes(FakeAsync a, MainState st) {
      st.openOrSwitch('222', 'notes', 'Notes');
      a.flushMicrotasks();
    }

    void end(MainState st, FakeSessionPort port, Object sid) {
      st.endCurrent();
      port.emit(ClosedEvent(sid, 'rapp-client: quit'));
    }

    List<(String, Map<String, Object?>)> callsOf(FakeSessionPort p, String m) => p.calls.where((c) => c.$1 == m).toList();

    TransferProgressEvent prog(Object sid, int id, TransferState state, {String? path}) =>
        TransferProgressEvent(sid, id, true, 'a.log', 10, 100, state, path, null);

    test('clips from two sessions land in one list with sources', () {
      env((a, t, port, st) {
        openNotes(a, st);
        port.emit(const ClipsEvent(1, [ClipRow(1, 'one', true)]));
        port.emit(const ClipsEvent(2, [ClipRow(1, 'two', true)]));
        final c = st.resources.clips;
        expect(c.map((e) => e.title), ['two', 'one']);
        expect(c.map((e) => e.source), ['Notes @ air', 'Calculator @ mini']);
      });
    });

    test('copyLocal of a live unpinned entry picks the clip', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        final e = st.resources.clips.single;
        expect(st.canCopy(e), true);
        expect(st.copyBlockedWord(e), isNull);
        st.copyLocal(e);
        expect(callsOf(port, 'clip_pick').single.$2, {'sid': 1, 'clip': 7, 'insert': false});
      });
    });

    test('an unsupported entry is grey with 不支持', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'dir', false)]));
        final e = st.resources.clips.single;
        expect(st.copyBlockedWord(e), '不支持');
        expect(st.canCopy(e), false);
        expect(st.canPin(e), false);
      });
    });

    test('pinning waits for the copy then marks pinned', () {
      final gated = _GatedFetchPort();
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        final e = st.resources.clips.single;
        st.togglePin(e);
        a.flushMicrotasks();
        expect(e.pinning, true);
        expect(e.pinned, false);
        expect(st.canPin(e), false);
        gated.gate.complete({'copy': 5});
        a.flushMicrotasks();
        expect(e.pinned, true);
        expect(e.pinning, false);
        expect(e.copy, 5);
      }, usePort: gated);
    });

    test('a failed pin hints and stays unpinned', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        final e = st.resources.clips.single;
        port.fetchReply = {'error': 'unknown clip'};
        st.togglePin(e);
        a.flushMicrotasks();
        expect(e.pinned, false);
        expect(e.pinning, false);
        expect(st.hint, '这条太旧了，远端已不保留');
      });
    });

    test('ending a session keeps pinned entries and drops the rest', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(2, 'b', true), ClipRow(1, 'a', true)]));
        final pinned = st.resources.clips.firstWhere((e) => e.title == 'a');
        st.togglePin(pinned);
        a.flushMicrotasks();
        port.emit(prog(1, 5, TransferState.running));
        expect(st.resources.running, hasLength(1));
        end(st, port, 1);
        a.flushMicrotasks();
        expect(st.resources.clips.map((e) => e.title), ['a']);
        expect(st.resources.running, isEmpty);
        expect(st.resources.ended.single.state, TransferState.cancelled);
        port.calls.clear();
        st.copyLocal(pinned);
        a.flushMicrotasks();
        expect(callsOf(port, 'copy_local').single.$2, {'copy': 1});
        expect(callsOf(port, 'clip_pick'), isEmpty);
      });
    });

    test('late transfer events after an end are ignored', () {
      env((a, t, port, st) {
        port.emit(prog(1, 5, TransferState.running));
        const sid = 1;
        end(st, port, 1);
        a.flushMicrotasks();
        port.emit(prog(sid, 5, TransferState.running));
        expect(st.resources.running, isEmpty);
      });
    });

    test('a hub restart that hands out the same sid again starts the resources afresh (S6-4b)', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'old', true)]));
        final old = st.resources.clips.single;
        st.togglePin(old);
        a.flushMicrotasks();
        port.emit(prog(1, 5, TransferState.done));
        end(st, port, 1);
        a.flushMicrotasks();
        // 重启服务: the hub counts from 1 again, so the same app gets sid 1 once more.
        st.openOrSwitch('111', 'calc', 'Calculator');
        a.flushMicrotasks();
        expect(st.currentRemote!.sid, 1);
        port.emit(prog(1, 5, TransferState.running));
        expect(st.resources.running, hasLength(1));
        port.emit(prog(1, 5, TransferState.done));
        expect(st.resources.ended, hasLength(2));
        port.emit(const ClipsEvent(1, [ClipRow(7, 'new', true)]));
        final fresh = st.resources.clips.firstWhere((e) => e.title == 'new');
        expect(old.ended, true);
        expect(st.canInsert(old), false);
        expect(st.canInsert(fresh), true);
        port.calls.clear();
        st.copyLocal(old);
        a.flushMicrotasks();
        expect(callsOf(port, 'copy_local').single.$2, {'copy': 1});
        expect(callsOf(port, 'clip_pick'), isEmpty);
        st.copyLocal(fresh);
        expect(callsOf(port, 'clip_pick').single.$2, {'sid': 1, 'clip': 7, 'insert': false});
        st.cancelTransfer(st.resources.ended.first);
        expect(callsOf(port, 'cancel_transfer').single.$2, {'sid': 1, 'id': 5});
      });
    });

    test('a disconnect, then a reconnect, keeps the words and offers no 插入', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        final e = st.resources.clips.single;
        expect(st.copyBlockedWord(e), '远端已断开，复制不到');
        st.reconnect('111/calc');
        a.flushMicrotasks();
        expect(st.copyBlockedWord(e), '重连前的，复制不到');
        expect(st.canInsert(e), false);
      });
    });

    test('a disconnected session greys its entries', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        final e = st.resources.clips.single;
        expect(st.copyBlockedWord(e), '远端已断开，复制不到');
        expect(st.canPin(e), false);
        port.calls.clear();
        st.copyLocal(e);
        a.flushMicrotasks();
        expect(port.calls, isEmpty);
      });
    });

    test('entries from before a reconnect stay grey and never pick', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'old', true)]));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/calc');
        a.flushMicrotasks();
        port.emit(const ClipsEvent(11, [ClipRow(1, 'new', true)]));
        final old = st.resources.clips.firstWhere((e) => e.title == 'old');
        final fresh = st.resources.clips.firstWhere((e) => e.title == 'new');
        expect(st.copyBlockedWord(old), '重连前的，复制不到');
        port.calls.clear();
        st.copyLocal(old);
        expect(callsOf(port, 'clip_pick'), isEmpty);
        expect(st.copyBlockedWord(fresh), isNull);
        st.copyLocal(fresh);
        expect(callsOf(port, 'clip_pick').single.$2, {'sid': 11, 'clip': 1, 'insert': false});
      });
    });

    test('unpinning after the session ended removes it and drops the copy', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        final e = st.resources.clips.single;
        st.togglePin(e);
        a.flushMicrotasks();
        end(st, port, 1);
        a.flushMicrotasks();
        expect(e.ended, true);
        port.calls.clear();
        st.togglePin(e);
        a.flushMicrotasks();
        expect(st.resources.clips, isEmpty);
        expect(callsOf(port, 'drop_copy').single.$2, {'copy': 1});
      });
    });

    test('the pin reply after the entry was removed drops the copy', () {
      final gated = _GatedFetchPort();
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        final e = st.resources.clips.single;
        st.togglePin(e);
        a.flushMicrotasks();
        end(st, port, 1);
        a.flushMicrotasks();
        expect(st.resources.clips, isEmpty);
        final before = st.hint;
        gated.gate.complete({'copy': 9});
        a.flushMicrotasks();
        expect(callsOf(port, 'drop_copy').single.$2, {'copy': 9});
        expect(st.hint, before);
      }, usePort: gated);
    });

    test('pinning saves the copy to the data dir and hints once', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true), ClipRow(8, 'two', true)]));
        port.pinSaveReply = {'path': '${tmp.path}/clipboard/x.md'};
        st.togglePin(st.resources.clips.last);
        a.flushMicrotasks();
        final c = callsOf(port, 'pin_save').single.$2;
        expect(c['text_dir'], '${tmp.path}/clipboard');
        expect(c['file_dir'], '${tmp.path}/files/clipboard');
        expect(c['copy'], 1);
        expect(st.resources.clips.last.path, '${tmp.path}/clipboard/x.md');
        expect(st.hint, pinHint);
        expect(File('${tmp.path}/local/$pinHintMarker').existsSync(), true);
        st.hint = '';
        st.togglePin(st.resources.clips.first);
        a.flushMicrotasks();
        expect(callsOf(port, 'pin_save').length, 2);
        expect(st.hint, isNot(pinHint));
      });
    });

    test('a pin whose save failed stays pinned in memory without a hint', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        st.togglePin(st.resources.clips.single);
        a.flushMicrotasks();
        final e = st.resources.clips.single;
        expect(e.pinned, true);
        expect(e.path, isNull);
        expect(st.hint, isNot(pinHint));
        expect(File('${tmp.path}/local/$pinHintMarker').existsSync(), false);
      });
    });

    test('unpinning deletes the file', () {
      final f = File('${tmp.path}/saved.md')..writeAsStringSync('x');
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true)]));
        port.pinSaveReply = {'path': f.path};
        final e = st.resources.clips.single;
        st.togglePin(e);
        a.flushMicrotasks();
        expect(f.existsSync(), true);
        st.togglePin(e);
        a.flushMicrotasks();
        expect(f.existsSync(), false);
      });
    });

    test('restored pins load at start', () {
      final f = File('${tmp.path}/clipboard/20261113-090507-a.md');
      env((a, t, port, st) {
        a.flushMicrotasks();
        final e = st.resources.clips.single;
        expect(e.pinned, true);
        expect(e.ended, true);
        expect(e.source, '之前固定的');
        expect(e.title, 'a');
        expect(e.copy, 7);
        expect(e.path, f.path);
        expect(e.at, DateTime(2026, 11, 13, 9, 5, 7));
        expect(st.canInsert(e), false);
        expect(callsOf(port, 'pin_load').single.$2, {'path': f.path});
      }, usePort: FakeSessionPort()..pinLoadReply = {'copy': 7, 'kind': 'text'}, pre: () {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync('x');
      });
    });

    test('relocate moves pin paths to the new root', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'one', true), ClipRow(8, 'two', true)]));
        port.pinSaveReply = {'path': '${tmp.path}/clipboard/x.md'};
        st.togglePin(st.resources.clips.last);
        a.flushMicrotasks();
        port.pinSaveReply = {'path': '${tmp.path}2/clipboard/y.md'};
        st.togglePin(st.resources.clips.first);
        a.flushMicrotasks();
        st.relocate(const DataDir('/new/root'));
        expect(st.resources.clips.last.path, '/new/root/clipboard/x.md');
        expect(st.resources.clips.first.path, '${tmp.path}2/clipboard/y.md');
      });
    });

    test('reveal of a missing file hints', () {
      env((a, t, port, st) {
        port.revealReply = false;
        port.emit(prog(1, 5, TransferState.done, path: '/tmp/x/a.log'));
        final row = st.resources.ended.single;
        st.reveal(row);
        a.flushMicrotasks();
        expect(st.hint, '文件不在了：a.log');
      });
    });

    test('cancelTransfer sends the id', () {
      env((a, t, port, st) {
        port.emit(prog(1, 5, TransferState.running));
        st.cancelTransfer(st.resources.running.single);
        expect(callsOf(port, 'cancel_transfer').single.$2, {'sid': 1, 'id': 5});
      });
    });

    test('the hub exiting fails running transfers with 没传完', () {
      env((a, t, port, st) {
        port.emit(prog(1, 5, TransferState.running));
        t.die();
        a.flushMicrotasks();
        a.elapse(const Duration(seconds: 1));
        expect(st.resources.running, isEmpty);
        expect(st.resources.ended.single.state, TransferState.failed);
        expect(st.resources.ended.single.error, '没传完');
      });
    });

    test('after a failed reconnect the old entries say 已断开 again', () {
      env((a, t, port, st) {
        port.emit(const ClipsEvent(1, [ClipRow(7, 'old', true)]));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        t.onSend = (m) {
          if (m['cmd'] == 'open') t.emit({'event': 'error', 'error': 'offline', 'req': m['req']});
        };
        st.reconnect('111/calc');
        a.flushMicrotasks();
        expect(st.copyBlockedWord(st.resources.clips.single), '远端已断开，复制不到');
      });
    });

    test('copyLocal and reveal answering after dispose do nothing', () {
      fakeAsync((a) {
        final port = FakeSessionPort()
          ..copyLocalReply = false
          ..revealReply = false;
        final st = MainState(hub: null, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
        final row = TransferRow(1, 1, 5, 'k', true, 'a.log', 's', 1, 1, TransferState.done)..path = '/tmp/x/a.log';
        st.copyLocal(ClipEntry(1, 'k', 1, 1, ClipKind.text, 't', 's', DateTime(2026))..copy = 3);
        st.reveal(row);
        final before = st.hint;
        st.dispose();
        a.flushMicrotasks();
        expect(st.hint, before);
      });
    });

    test('showPanel does not close an open tab', () {
      env((a, t, port, st) {
        st.showPanel(PanelTab.resources);
        st.showPanel(PanelTab.resources);
        expect(st.panel, PanelTab.resources);
      });
    });
  });

  group('endedHint', () {
    test('maps runner and hub reasons', () {
      expect(endedHint('X', 'rapp-client: quit'), '已结束 X');
      expect(endedHint('X', 'host says: X quit'), 'X 已结束：远端关闭了 app');
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

/// A port whose `fetch_clip` waits for the test to answer.
class _GatedFetchPort extends FakeSessionPort {
  // Made on the first fetch, inside the test's fake zone, so the test's microtask flush reaches it.
  late final Completer<Map<String, Object?>> gate;

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) {
    if (method != 'fetch_clip') return super.invoke(method, args);
    calls.add((method, args));
    gate = Completer<Map<String, Object?>>();
    return gate.future;
  }
}
