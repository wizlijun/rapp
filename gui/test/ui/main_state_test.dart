import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/app_profile_store.dart';
import 'package:rapp/embed/stream_choice.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/history/draft_store.dart';
import 'package:rapp/history/input_recorder.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/lifecycle.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/pin_files.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/project_positions.dart';
import 'package:rapp/ui/resources_state.dart';
import 'package:rapp/ui/session_model.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/unlock.dart';
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

  test('quickAutoHide: null pref is on for macOS, off for iOS', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(s.quickAutoHide, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(s.quickAutoHide, isFalse);
    s.setQuickAutoHide(true);
    expect(s.quickAutoHide, isTrue);
    expect(s.prefs.quickAutoHide, isTrue);
  });

  test('setQuickHidden keeps the two kinds apart and saves', () {
    s.setQuickHidden(term: true, hidden: true);
    expect([s.prefs.quickHiddenTerm, s.prefs.quickHiddenApp], [true, true]);
    s.setQuickHidden(term: false, hidden: false);
    expect([s.prefs.quickHiddenTerm, s.prefs.quickHiddenApp], [true, false]);
  });

  test('placeComposer on a text terminal writes term_composer_at; composerAtOf reads it for every terminal', () {
    final term = FakeTermSessionPort()..seed(5)..seed(6);
    final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), termPort: term);
    addTearDown(st.dispose);
    const p = InputPoint(0.3, 120, fromBottom: true);
    final a = RemoteSession(5, 'sh'), b = RemoteSession(6, 'zsh');
    expect(st.composerAtOf(a), isNull);
    st.placeComposer(a, p);
    expect(st.prefs.termComposerAt, p);
    expect(st.composerAtOf(b), p);
    st.placeComposer(b, null);
    expect(st.composerAtOf(a), isNull);
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

  test('addPhrase appends once and saves; a repeat or a blank is refused', () {
    Directory('${tmp.path}/local').createSync(recursive: true);
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    s.setPhrases(const [Phrase('继续')]);
    expect(s.addPhrase('跑一下测试'), isTrue);
    expect(s.addPhrase('继续'), isFalse);
    expect(s.addPhrase('  '), isFalse);
    expect(UiPrefs.load(s.data.prefsDir()!).phrases, const [Phrase('继续'), Phrase('跑一下测试')]);
  });

  test('setFirst persists and leaves the current grouping alone', () {
    Directory('${tmp.path}/local').createSync(recursive: true);
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    s.setGrouping(Grouping.app);
    s.setFirst(FirstLayer.project);
    expect(s.grouping, Grouping.app);
    final s2 = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs.load(s.data.prefsDir()!));
    addTearDown(s2.dispose);
    expect(s2.prefs.first, FirstLayer.project);
    expect(s2.grouping, Grouping.project);
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
    expect(s.hubProblem, 'rapp-hub 已退出 — 重启 rApp 以恢复');
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
    expect(s.remoteOnline, 1);
    expect(s.onlineDevices, 2); // 本机 counts too
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
        {int sessions = 1, bool withPort = true, AppProfileStore? profiles, void Function(String)? log, String? app, String path = 'lan',
        UnlockStore? unlockStore, String? stateRulesJson}) {
      fakeAsync((a) {
        final t = FakeTransport();
        final hub = HubClient(t);
        final port = FakeSessionPort();
        final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: withPort ? port : null, profiles: profiles, log: log,
            unlockStore: unlockStore, builtinStateRules: stateRulesJson);
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
              'event': 'opened', 'sid': n, 'id': m['id'], 'app': m['app'], 'path': path,
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

  group('app state rules', () {
    final rulesJson = File('assets/state_rules.json').readAsStringSync();
    const codex = 'com.openai.codex';
    AppProfileStore store(String? setting) => AppProfileStore('${tmp.path}/shared',
        mine: [if (setting != null) AppProfile(ids: [codex], stateRules: setting)], builtin: []);
    List<(String, Map<String, Object?>)> sent(FakeSessionPort p) => [for (final c in p.calls) if (c.$1 == 'state_rules') c];
    String report(String state, {bool sure = false, String? kind, String health = 'ok', Map<String, int> counts = const {}}) =>
        jsonEncode({'state': state, 'sure': sure, 'kind': kind, 'health': health, 'counts': counts, 'by': <String>[]});

    test('rules go out on every ready of an app session, not for terminals or the desktop', () {
      final sid = codex.length;
      env((a, t, port, st, hints) {
        expect(sent(port), isEmpty); // not before ready
        port.emit(ReadyEvent(sid, 'ChatGPT'));
        final first = sent(port).single;
        expect(first.$2['sid'], sid);
        final json = jsonDecode(first.$2['json']! as String) as Map;
        expect(json['id'], 'chatgpt-desktop');
        expect(json.containsKey('extends'), isFalse); // resolved
        expect(st.rulesOf(sid)!.id, 'chatgpt-desktop');
        port.emit(DisconnectedEvent(sid, 'connection closed'));
        st.reconnect('111/$codex');
        a.flushMicrotasks();
        final sid2 = st.currentRecord!.sid!;
        expect(sid2, isNot(sid));
        port.emit(ReadyEvent(sid2, 'ChatGPT'));
        expect(sent(port), hasLength(2));
        expect(sent(port).last.$2['sid'], sid2);
      }, app: codex, stateRulesJson: rulesJson);
      env((a, t, port, st, hints) {
        port.emit(ReadyEvent('desktop:'.length, 'Desktop'));
        expect(sent(port), isEmpty);
      }, app: 'desktop:', stateRulesJson: rulesJson);
      env((a, t, port, st, hints) {
        port.emit(ReadyEvent('term:sh'.length, 'sh'));
        expect(sent(port), isEmpty);
      }, app: 'term:sh', stateRulesJson: rulesJson);
      env((a, t, port, st, hints) {
        port.emit(ReadyEvent(codex.length, 'ChatGPT'));
        expect(sent(port), isEmpty);
        expect(st.rulesOf(codex.length), isNull);
      }, app: codex, stateRulesJson: rulesJson, profiles: store('off'));
      env((a, t, port, st, hints) {
        port.emit(ReadyEvent(codex.length, 'ChatGPT'));
        expect(jsonDecode(sent(port).single.$2['json']! as String)['id'], 'claude-desktop');
      }, app: codex, stateRulesJson: rulesJson, profiles: store('claude-desktop'));
    });

    test('inferred state drives the lamp, the row word and the overview, marked 推断', () {
      final sid = codex.length;
      env((a, t, port, st, hints) {
        port.emit(ReadyEvent(sid, 'ChatGPT'));
        port.emit(WindowsEvent(sid, [RemoteWindow(id: 1, parent: 0, kind: WindowKind.normal, title: 't',
            rect: const Rect.fromLTWH(0, 0, 10, 10), titleBar: 0, resizable: true, focused: true, texture: 1,
            visible: const Rect.fromLTWH(0, 0, 1, 1))]));
        port.emit(TrafficEvent(sid, 100, 1));
        SessionEntry e() => st.entries.single;
        port.emit(AppStateEvent(sid, report('working')));
        expect(e().lamp, Lamp.active);
        expect(e().ps!.state, 'working');
        expect(e().inferred, isTrue);
        port.emit(AppStateEvent(sid, report('done')));
        expect(e().lamp, Lamp.idle);
        port.emit(AppStateEvent(sid, report('blocked', kind: 'permission')));
        expect(e().lamp, Lamp.waiting);
        port.emit(AppStateEvent(sid, report('idle')));
        expect(e().lamp, Lamp.idle);
        // unfit: no state, so the lamp is what it is without rules
        final without = st.currentRemote!.idle ? Lamp.idle : Lamp.active;
        port.emit(AppStateEvent(sid, jsonEncode({'state': null, 'health': 'unfit'})));
        expect(e().lamp, without);
        expect(e().ps, isNull);
        expect(e().inferred, isFalse);
      }, app: codex, stateRulesJson: rulesJson);
    });

    test('a stale report does not light the waiting lamp or 需要你', () {
      final sid = codex.length;
      env((a, t, port, st, hints) {
        port.emit(ReadyEvent(sid, 'ChatGPT'));
        port.emit(TrafficEvent(sid, 100, 1));
        port.emit(AppStateEvent(sid, report('blocked', sure: true, health: 'unfit')));
        expect(st.entries.single.lamp, isNot(Lamp.waiting));
        expect(st.needs.where((n) => n.kind == NeedKind.app), isEmpty);
      }, app: codex, stateRulesJson: rulesJson);
    });

    test('only a sure block is a need', () {
      final sid = codex.length;
      env((a, t, port, st, hints) {
        port.emit(ReadyEvent(sid, 'ChatGPT'));
        port.emit(TrafficEvent(sid, 100, 1));
        port.emit(AppStateEvent(sid, report('blocked', kind: 'permission')));
        expect(st.needs.where((n) => n.kind == NeedKind.app), isEmpty);
        port.emit(AppStateEvent(sid, report('blocked', sure: true, kind: 'permission')));
        final n = st.needs.singleWhere((n) => n.kind == NeedKind.app);
        expect(n.text, '${st.currentRecord!.appName} @ ${st.deviceName('111')}：等确认');
        expect(n.target, '111/$codex');
        st.goToNeed(n);
        expect(st.currentKey, '111/$codex');
        port.emit(AppStateEvent(sid, report('working')));
        expect(st.needs.where((n) => n.kind == NeedKind.app), isEmpty);
      }, app: codex, stateRulesJson: rulesJson);
    });

    test('inferred changes enter the status queue with inferred: true', () {
      final sid = codex.length;
      env((a, t, port, st, hints) {
        port.emit(ReadyEvent(sid, 'ChatGPT'));
        port.emit(AppStateEvent(sid, report('working'))); // the first report is the starting point
        expect(st.hintHistory.where((h) => h.inferred), isEmpty);
        port.emit(AppStateEvent(sid, report('done')));
        final h = st.hintHistory.first;
        expect(h.inferred, isTrue);
        expect(h.text, endsWith('：完成'));
        expect(h.device, '111');
        expect(h.app, codex);
        expect(h.lamp, Lamp.idle);
        final n = st.hintHistory.length;
        port.emit(AppStateEvent(sid, report('done', counts: {'rowDot': 2}))); // only counts changed
        expect(st.hintHistory, hasLength(n));
        port.emit(AppStateEvent(sid, jsonEncode({'state': null, 'health': 'unfit'}))); // null is not a change
        expect(st.hintHistory, hasLength(n));
      }, app: codex, stateRulesJson: rulesJson);
    });
  });

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

    test('placeComposer saves for the session\'s app and the session sees it; an unknown app saves nothing', () {
      env((a, t, port, st, hints) {
        const p = InputPoint(0.2, 8, fromBottom: true);
        st.placeComposer(RemoteSession(99, 'X'), p); // appId ''
        expect(st.profiles.mine, isEmpty);
        st.placeComposer(st.currentRemote!, p);
        expect(st.currentRemote!.profile.composerAt, p);
        expect(st.composerAtOf(st.currentRemote!), p); // an app: the profile, not the terminal place
        expect(st.prefs.termComposerAt, isNull);
        st.placeComposer(st.currentRemote!, null);
        expect(st.currentRemote!.profile.composerAt, isNull);
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
        final ed = FakeEditor();
        rs.composer.attach(ed);
        ed.value = 'ls';
        rs.composer.submit();
        a.flushMicrotasks();
        port.emit(ComposerStateEvent(sid, done: const ComposerDone(1, null)));
        expect(calls(port, 'key').single.$2, {'sid': sid, 'keyCode': 36, 'modifiers': 0});
        ed.value = 'x';
        rs.composer.submit();
        a.flushMicrotasks();
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

    test('pinned is automatic saving off: a manual pick is only the ceiling', () {
      env((a, t, port, st, hints) {
        st.currentRemote!.setChoice(const StreamChoice('color16', 'adaptive', 5), manual: true);
        expect(port.calls.last.$1, 'set_stream');
        expect(port.calls.last.$2['pinned'], isNot(true));
        st.setAutoSaveTraffic(false);
        expect(port.calls.last.$1, 'set_stream');
        expect(port.calls.last.$2['pinned'], true);
        expect(st.prefs.autoSaveTraffic, false);
      });
    });

    group('smart preset asks A for the focus region', () {
      RemoteWindow w(int id) => RemoteWindow(
            id: id, parent: 0, kind: WindowKind.normal, title: 'w$id', rect: const Rect.fromLTWH(0, 0, 400, 300),
            titleBar: 28, resizable: true, focused: false, texture: id, visible: const Rect.fromLTWH(0, 0, 1, 1),
          );
      List<Map<String, Object?>> sets(FakeSessionPort port) => [for (final c in port.calls) if (c.$1 == 'set_stream') c.$2];

      test('smart is never pinned and asks for focus, even with automatic saving off', () {
        env((a, t, port, st, hints) {
          st.setAutoSaveTraffic(false);
          expect(port.calls.last.$2['pinned'], true);
          st.currentRemote!.setChoice(presetSmart, manual: true);
          final m = port.calls.last;
          expect(m.$1, 'set_stream');
          expect(m.$2['pinned'], isNot(true));
          expect(m.$2['focus'], true);
        });
      });

      test('only the focus changing resends; nothing changing does not; leaving smart clears rs.focus', () {
        env((a, t, port, st, hints) {
          final rs = st.currentRemote!;
          rs.setChoice(presetSmart, manual: true);
          final n = sets(port).length;
          st.setAutoSaveTraffic(true); // a no-op for the wire
          expect(sets(port).length, n);
          rs.apply(WindowsEvent(1, [w(5)]));
          rs.apply(FocusRegionEvent(1, 5, const [Rect.fromLTWH(0, 0, 4, 4)]));
          expect(rs.focus, isNotNull);
          rs.setChoice(presetSmart.copyWith(), manual: true); // same numbers, smart off
          expect(sets(port).length, n + 1);
          expect(sets(port).last.containsKey('focus'), false);
          expect(rs.focus, isNull);
        });
      });

      test('an app whose profile has focusPane off never asks', () {
        final store = AppProfileStore('${tmp.path}/shared', mine: [AppProfile(ids: ['a'], focusPane: false)], builtin: []);
        env(profiles: store, (a, t, port, st, hints) {
          st.currentRemote!.setChoice(presetSmart.copyWith(fps: 5), manual: true);
          st.currentRemote!.setChoice(presetSmart, manual: true);
          expect(sets(port).where((m) => m.containsKey('focus')), isEmpty);
          expect(sets(port).last['pinned'], isNot(true));
        });
      });

      test('turning focusPane off for the app, mid-session, resends without focus and clears rs.focus', () {
        final store = AppProfileStore('${tmp.path}/shared', mine: [], builtin: []);
        env(profiles: store, (a, t, port, st, hints) {
          final rs = st.currentRemote!;
          rs.setChoice(presetSmart, manual: true);
          expect(sets(port).last['focus'], true);
          rs.apply(WindowsEvent(1, [w(5)]));
          rs.apply(FocusRegionEvent(1, 5, const [Rect.fromLTWH(0, 0, 4, 4)]));
          expect(rs.focus, isNotNull);
          final n = sets(port).length;
          store.put(AppProfile(ids: ['a'], focusPane: false));
          expect(sets(port).length, n + 1);
          expect(sets(port).last.containsKey('focus'), false);
          expect(rs.focus, isNull);
        });
      });

      test('start of a smart session sends focus; the record keeps the smart choice', () {
        env((a, t, port, st, hints) {
          st.currentRemote!.setChoice(presetSmart, manual: true);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          expect(st.currentRecord!.choice, presetSmart);
          expect(st.currentRecord!.choice.smart, true);
          st.reconnect('111/a');
          a.flushMicrotasks();
          final i = port.calls.lastIndexWhere((c) => c.$1 == 'start');
          expect(i, isNonNegative);
          expect(port.calls[i + 1].$1, 'set_stream');
          expect(port.calls[i + 1].$2['focus'], true);
          expect(port.calls[i + 1].$2['pinned'], isNot(true));
          expect(st.currentRemote!.choice.smart, true);
        });
      });
    });

    test('the hub is asked for the network level at once', () {
      env((a, t, port, st, hints) {
        expect(t.sent.where((m) => m['cmd'] == 'net').length, 1);
      });
    });

    group('automatic reconnect', () {
      int opens(FakeTransport t) => t.sent.where((m) => m['cmd'] == 'open').length;
      void failOpens(FakeTransport t, [String error = 'timed out']) {
        final inner = t.onSend;
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({'event': 'error', 'error': error, 'req': m['req']});
          } else {
            inner?.call(m);
          }
        };
      }
      List<Map<String, dynamic>> watches(FakeTransport t) => [for (final m in t.sent) if (m['cmd'] == 'watch') m];
      void net(FakeTransport t, String level, [int? rtt]) =>
          t.emit({'event': 'net', 'level': level, 'loss': 0, 'rtt_ms': ?rtt});

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
          expect(hints, ['Calculator 已断开：连接超时']);
        });
      });

      test('offline waits for the host: watch on, no timer; presence online reconnects at once', () {
        env((a, t, port, st, hints) {
          final send = t.onSend!;
          failOpens(t, 'offline');
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 1));
          a.flushMicrotasks();
          final n = opens(t);
          expect(st.currentRecord!.reason, contains('offline'));
          expect(watches(t), [
            {'cmd': 'watch', 'id': '111', 'on': true},
          ]);
          expect(st.waitWordOf(st.currentRecord!), '对方离线，上线后自动连');
          a.elapse(const Duration(minutes: 5));
          expect(opens(t), n); // the hub watches; nothing is tried meanwhile
          // Back, but still offline when tried: the watch starts again.
          t.emit({'event': 'presence', 'id': '111', 'online': true});
          a.elapse(Duration.zero);
          a.flushMicrotasks();
          expect(opens(t), n + 1);
          expect(watches(t).length, 2);
          expect(watches(t).last['on'], true);
          t.onSend = send;
          t.emit({'event': 'presence', 'id': '111', 'online': true});
          a.elapse(Duration.zero);
          a.flushMicrotasks();
          expect(st.currentRecord!.phase, Phase.live);
          expect(watches(t).length, 2); // the hub's watch ended with its answer
        });
      });

      test('stopping an offline wait stops the watch', () {
        env((a, t, port, st, hints) {
          failOpens(t, 'offline');
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 1));
          a.flushMicrotasks();
          st.stopReconnectCurrent();
          expect(watches(t).map((m) => m['on']), [true, false]);
        });
      });

      test('a relayed session waits while the relay link is down, then reconnects 200 ms apart', () {
        env(sessions: 3, path: 'relay', (a, t, port, st, hints) {
          net(t, 'strong', 40);
          final send = t.onSend!;
          failOpens(t);
          net(t, 'down');
          for (final sid in [1, 2, 3]) {
            port.emit(DisconnectedEvent(sid, 'connection closed'));
          }
          a.flushMicrotasks();
          final n = opens(t);
          a.elapse(const Duration(minutes: 2));
          expect(opens(t), n);
          final r = st.recordFor('111/a')!;
          expect(r.retry, isNotNull);
          expect(st.waitWordOf(r), '连不上中继，通了自动重连');
          final times = <int>[];
          final start = a.getClock(DateTime(2026)).now();
          t.onSend = (m) {
            if (m['cmd'] == 'open') times.add(a.getClock(DateTime(2026)).now().difference(start).inMilliseconds);
            send(m);
          };
          net(t, 'ok', 160);
          a.elapse(const Duration(seconds: 1));
          a.flushMicrotasks();
          expect(times, [0, 200, 400]);
          expect(st.recordFor('111/a')!.phase, Phase.live);
        });
      });

      test('a LAN session is not held by the relay link being down', () {
        env((a, t, port, st, hints) {
          net(t, 'strong', 40);
          net(t, 'down');
          final n = opens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 1));
          a.flushMicrotasks();
          expect(opens(t), n + 1);
        });
      });

      test('a relay timer that comes due while the link is down holds, and the link back retries', () {
        env(path: 'relay', (a, t, port, st, hints) {
          net(t, 'strong', 40);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          net(t, 'down');
          final n = opens(t);
          a.elapse(const Duration(seconds: 30));
          expect(opens(t), n);
          net(t, 'weak', 400);
          a.elapse(Duration.zero);
          a.flushMicrotasks();
          expect(opens(t), n + 1);
        });
      });

      test('the link up but the session dropped on the relay: 对方网络不通', () {
        env(path: 'relay', (a, t, port, st, hints) {
          net(t, 'ok', 120);
          failOpens(t);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.flushMicrotasks();
          expect(st.waitWordOf(st.currentRecord!), '对方网络不通，正在重试…');
          net(t, 'down');
          a.flushMicrotasks();
          expect(st.waitWordOf(st.currentRecord!), '连不上中继，通了自动重连');
        });
      });

      test('a network change (iOS pathChanged) tells the hub', () {
        env((a, t, port, st, hints) {
          st.netChanged();
          a.flushMicrotasks();
          expect(t.sent.where((m) => m['cmd'] == 'net_changed').length, 1);
        });
      });

      test('a stalled picture asks the hub to probe the relay', () {
        env((a, t, port, st, hints) {
          port.emit(const StalledEvent(1, true));
          port.emit(const StalledEvent(1, false));
          a.flushMicrotasks();
          expect(t.sent.where((m) => m['cmd'] == 'net_suspect').length, 1);
        });
      });

      test('a relayed session far slower than the relay link marks its device 网络弱', () {
        env(path: 'relay', (a, t, port, st, hints) {
          port.emit(const ReadyEvent(1, 'Calculator'));
          net(t, 'ok', 100);
          port.emit(const RttEvent(1, 350));
          a.flushMicrotasks();
          expect(st.peerWeak('111'), false, reason: 'the far side is 250 ms');
          port.emit(const RttEvent(1, 420));
          a.flushMicrotasks();
          expect(st.peerWeak('111'), true);
          net(t, 'none');
          a.flushMicrotasks();
          expect(st.peerWeak('111'), false, reason: 'no relay measured: no split');
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
                t.emit({'event': 'error', 'error': ++tries == 1 ? 'timed out' : reason, 'req': m['req']});
              }
            };
            port.emit(const DisconnectedEvent(1, 'connection closed'));
            a.elapse(const Duration(seconds: 60));
            expect(tries, 2);
            expect(st.currentRecord!.retry, isNull);
          });
        });
      }

      test('auto reconnect keeps saving off', () {
        env((a, t, port, st, hints) {
          st.setAutoSaveTraffic(false);
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.elapse(const Duration(seconds: 1));
          a.flushMicrotasks();
          expect(port.calls.last.$1, 'set_stream');
          expect(port.calls.last.$2['pinned'], true);
        });
      });
    });

    test('saving off survives reconnect; on, the reconnect sends no pin', () {
      env((a, t, port, st, hints) {
        st.setAutoSaveTraffic(false);
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        expect(port.calls.last.$1, 'set_stream');
        expect(port.calls.last.$2, containsPair('sid', 11));
        expect(port.calls.last.$2['pinned'], true);
        st.setAutoSaveTraffic(true);
        expect(port.calls.last.$2['pinned'], isNot(true));
        port.emit(const DisconnectedEvent(11, 'connection closed'));
        final n = port.calls.length;
        st.reconnect('111/a');
        a.flushMicrotasks();
        expect(port.calls.skip(n).where((c) => c.$1 == 'set_stream'), isEmpty);
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

    group('pause out of sight (v15)', () {
      void frames(FakeSessionPort port, int sid) => port.emit(TrafficEvent(sid, 900, 3));

      test('after its first frame an off-stage session pauses at 0; back on stage it streams', () {
        env((a, t, port, st, hints) {
          expect(sets(port, 1).last['fps'], 1, reason: 'no first frame yet: not paused');
          frames(port, 1);
          expect(sets(port, 1).last['fps'], 0);
          st.select('111/a');
          expect(sets(port, 1).last['fps'], 15);
          expect(st.remote[1]!.choice.fps, 15, reason: 'the choice never changes');
          frames(port, 2);
          expect(sets(port, 2).last['fps'], 0);
        }, sessions: 2);
      });

      test('the main window out of sight pauses the stage session; a visible detached one keeps on', () {
        env((a, t, port, st, hints) {
          frames(port, 1);
          frames(port, 2);
          port.emit(const DetachedEvent(1, true));
          expect(sets(port, 1).last['fps'], 15);
          st.mainVisible = false;
          expect(sets(port, 2).last['fps'], 0);
          expect(sets(port, 1).last['fps'], 15);
          st.mainVisible = true;
          expect(sets(port, 2).last['fps'], 15);
        }, sessions: 2);
      });

      test('a detached window out of sight pauses; a new detach starts visible', () {
        env((a, t, port, st, hints) {
          frames(port, 1);
          port.emit(const DetachedEvent(1, true));
          port.emit(const WindowVisibleEvent(1, false));
          expect(sets(port, 1).last['fps'], 0);
          port.emit(const WindowVisibleEvent(1, true));
          expect(sets(port, 1).last['fps'], 15);
          port.emit(const WindowVisibleEvent(1, false));
          port.emit(const DetachedEvent(1, false));
          expect(sets(port, 1).last['fps'], 0, reason: 'attached, but not current');
          port.emit(const DetachedEvent(1, true));
          expect(sets(port, 1).last['fps'], 15);
        }, sessions: 2);
      });

      test('overview pauses every session that has a picture', () {
        env((a, t, port, st, hints) {
          frames(port, 2);
          expect(sets(port, 2).isEmpty ? 15 : sets(port, 2).last['fps'], 15);
          st.toggleOverview();
          expect(sets(port, 2).last['fps'], 0);
        }, sessions: 2);
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

    test('a covered press shows a notice: dismiss goes to A, the desktop opens, 15 s later it goes', () {
      env((a, t, port, st, hints) {
        port.emit(const CoveredEvent(1, 77, '通知中心', 'com.apple.notificationcenterui', true));
        final n = st.hostNotice!;
        expect(n.text, 'A 上「通知中心」的弹窗挡住了点击');
        expect((n.desktop, n.dismissable, n.bundle), (true, true, null));
        st.noticeDismiss();
        expect([for (final c in port.calls) if (c.$1 == 'dismiss_cover') c.$2], [{'sid': 1, 'id': 77}]);
        expect(st.hostNotice, isNull);
        // A system prompt: only the desktop is offered.
        port.emit(const CoveredEvent(1, 5, '安全代理', 'com.apple.SecurityAgent', false));
        expect(st.hostNotice!.dismissable, isFalse);
        a.elapse(const Duration(seconds: 14));
        expect(st.hostNotice, isNotNull);
        a.elapse(const Duration(seconds: 1));
        expect(st.hostNotice, isNull);
        port.emit(const CoveredEvent(1, 5, '安全代理', 'com.apple.SecurityAgent', false));
        st.noticeDesktop();
        a.flushMicrotasks();
        expect(t.sent.where((m) => m['cmd'] == 'open').last['app'], 'desktop:');
        expect(st.hostNotice, isNull);
      });
    });

    test('native host actions keep their sid and reject stale or unsafe dismissals', () {
      env((a, t, port, st, hints) {
        expect(st.currentKey, '111/aa');
        port.emit(const CoveredEvent(1, 77, '通知中心', 'bundle', true));
        final old = port.nativeCalls.where((c) => c.$1 == 'host_notice').last.$2;
        port.emit(const CoveredEvent(1, 88, '新提示', 'bundle', true));
        final fresh = port.nativeCalls.where((c) => c.$1 == 'host_notice').last.$2;
        port.emit(HostNoticeActionEvent(1, 'dismiss', old['epoch'] as int));
        expect(port.calls.where((c) => c.$1 == 'dismiss_cover'), isEmpty);
        port.emit(HostNoticeActionEvent(1, 'dismiss', fresh['epoch'] as int));
        expect(port.calls.where((c) => c.$1 == 'dismiss_cover').single.$2, {'sid': 1, 'id': 88});
        expect(st.currentKey, '111/aa');
        port.emit(const CoveredEvent(1, 99, '安全提示', 'bundle', false));
        final unsafe = port.nativeCalls.where((c) => c.$1 == 'host_notice').last.$2;
        expect((unsafe['actions'] as List).where((x) => x['id'] == 'dismiss'), isEmpty);
        port.emit(HostNoticeActionEvent(1, 'dismiss', unsafe['epoch'] as int));
        expect(port.calls.where((c) => c.$1 == 'dismiss_cover'), hasLength(1));
        a.elapse(hostNoticeFor);
        expect(port.nativeCalls.where((c) => c.$1 == 'host_notice').last.$2['text'], '');
      }, sessions: 2);
    });

    test('insertion during native handoff carries marks before DetachedEvent and preserves edited order', () {
      env((a, t, port, st, hints) {
        port.inlineNative = true;
        // The native window exists before its asynchronous detach acknowledgement.
        port.emit(const ComposerInsertEvent(1, PasteResult(text: 'x', blocks: [BlockChip(1, 'file')])));
        final sent = port.nativeCalls.where((c) => c.$1 == 'composer_insert').last.$2;
        final blocks = sent['blocks'] as List<BlockChip>;
        final mark = String.fromCharCode(blocks.single.mark!);
        expect(sent['text'], 'x');
        port.emit(const DetachedEvent(1, true));
        port.emit(ComposerDraftEvent(1, text: '前$mark后', inline: true, send: true));
        a.flushMicrotasks();
        expect(st.remote[1]!.composer.inFlight!.pieces(), [
          {'text': '前'}, {'block': 1}, {'text': '后'},
        ]);
      });
    });

    test('an app opened on A shows 「打开」, which opens it here; × just closes', () {
      env((a, t, port, st, hints) {
        port.emit(const AppOpenedEvent(1, 'com.apple.Safari', 'Safari'));
        expect(st.hostNotice!.text, 'A 上打开了「Safari」');
        st.closeHostNotice();
        expect(st.hostNotice, isNull);
        port.emit(const AppOpenedEvent(1, 'com.apple.Safari', 'Safari'));
        st.noticeOpen();
        a.flushMicrotasks();
        expect(t.sent.where((m) => m['cmd'] == 'open').last['app'], 'com.apple.Safari');
        expect(st.currentKey, '111/com.apple.Safari');
      });
      env((a, t, port, st, hints) {
        // Only the session on show has its notice on the stage.
        expect(st.currentKey, '111/aa');
        port.emit(const AppOpenedEvent(1, 'com.apple.Safari', 'Safari'));
        expect(st.hostNotice, isNull);
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
      test('openLogs closes the panel and takes the stage off', () {
        env((a, t, port, st, hints) {
          st.togglePanel();
          st.openLogs();
          expect(st.logs, true);
          expect(st.panel, isNull);
          st.closeLogs();
          expect(st.logs, false);
        }, sessions: 2);
      });

      test('select clears logs; so does toggleOverview', () {
        env((a, t, port, st, hints) {
          st.openLogs();
          st.select('111/a');
          expect(st.logs, false);
          st.openLogs();
          st.toggleOverview();
          expect(st.logs, false);
        }, sessions: 2);
      });

      test('全景 while logs are open from 全景 goes back to 全景, not the stage', () {
        env((a, t, port, st, hints) {
          st.toggleOverview();
          expect(st.overview, true);
          st.openLogs();
          expect((st.logs, st.overview), (true, true));
          st.toggleOverview();
          expect((st.logs, st.overview), (false, true));
          // From the stage too: 全景 ends on 全景.
          st.toggleOverview();
          expect(st.overview, false);
          st.openLogs();
          st.toggleOverview();
          expect((st.logs, st.overview), (false, true));
        }, sessions: 2);
      });

      test('with logs open Ctrl+Enter and focusPicture do nothing; the frame rate drops off-stage', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(2, [rw(7)]));
          st.remote[2]!.setChoice(const StreamChoice('color16', 'adaptive', 30));
          expect(sets(port, 2).last['fps'], 30);
          st.openLogs();
          expect(sets(port, 2).last['fps'], 1);
          st.composerKey();
          expect(st.currentRemote!.composer.open, false);
          st.focusPicture(2);
          expect(st.pictureFocused, isNull);
          st.closeLogs();
          expect(sets(port, 2).last['fps'], 30);
        }, sessions: 2);
      });

      test('stageLive is false while logs is open', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(1, [rw(3)]));
          expect(st.stageLive, true);
          st.openLogs();
          expect(st.stageLive, false);
          st.closeLogs();
          expect(st.stageLive, true);
        }, sessions: 2);
      });

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

    test('a reconnect carries the draft and the rows\' text over to the new session (I3)', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(3)]));
        final c = st.remote[1]!.composer;
        c.setDraft('x');
        c.submit();
        a.flushMicrotasks();
        c.done(0, 'boom');
        c.setDraft('y');
        c.submit();
        a.flushMicrotasks(); // in flight
        c.setDraft('abc');
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(WindowsEvent(11, [rw(3)]));
        expect(st.currentRemote!.sid, 11);
        final n = st.remote[11]!.composer;
        expect(n.draft, 'abc');
        expect([for (final o in n.failed) o.text], ['x', 'y']);
        expect(n.sending, false);
        expect(n.retry(n.failed.first), [
          {'text': 'x'},
        ]);
      });
    });

    test('a reconnect keeps the zoom of the window (the new session takes it over)', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(3)]));
        st.remote[1]!.zoomOf(3).zoomTo(2, const Offset(100, 100), const Rect.fromLTWH(0, 0, 200, 200), const Size(200, 200));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(WindowsEvent(11, [rw(3)]));
        expect(st.currentRemote!.sid, 11);
        expect(st.remote[11]!.zoomIfAny(3)?.z, 2);
        expect(st.remote[11]!.currentZoomed, true);
      });
    });

    test('the old sid closing during a reconnect carries the zoom over before the fresh table arrives', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(3)]));
        st.remote[1]!.zoomOf(3).zoomTo(2, const Offset(100, 100), const Rect.fromLTWH(0, 0, 200, 200), const Size(200, 200));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(const ClosedEvent(1, 'quit'));
        port.emit(WindowsEvent(11, [rw(3)]));
        expect(st.remote[11]!.zoomIfAny(3)?.z, 2);
      });
    });

    test('the old sid closing during a reconnect carries its composer text over too (I3)', () {
      env((a, t, port, st, hints) {
        final c = st.remote[1]!.composer;
        c.setDraft('x');
        c.submit();
        a.flushMicrotasks();
        c.setDraft('abc');
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(const ClosedEvent(1, 'quit'));
        final n = st.remote[11]!.composer;
        expect(n.draft, 'abc');
        expect([for (final o in n.failed) o.text], ['x']);
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

    group('background (iPad spec §9)', () {
      /// The hub answers `close` with `closed`, as rapp-hub does.
      void hubCloses(FakeTransport t) {
        final answer = t.onSend;
        t.onSend = (m) {
          answer?.call(m);
          if (m['cmd'] == 'close') t.emit({'event': 'closed', 'sid': m['sid'], 'reason': ?m['reason']});
        };
      }

      int openCount(FakeTransport t) => t.sent.where((m) => m['cmd'] == 'open').length;

      test('background freezes and closes with reason background', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(1, [rw(3)]));
          var ended = 0;
          unawaited(st.enterBackground(end: () async => ended++));
          a.flushMicrotasks();
          expect(st.backgrounded, true);
          expect(t.sent.where((m) => m['cmd'] == 'presence').single, {'cmd': 'presence', 'paused': true});
          expect(t.sent.where((m) => m['cmd'] == 'close').single, {'cmd': 'close', 'sid': 1, 'reason': 'background'});
          final r = st.recordFor('111/a')!;
          expect(r.phase, Phase.disconnected);
          expect(r.frozen, true);
          expect(disconnectWord(r.reason), '切到后台');
          expect(r.retry, isNull);
          expect(st.currentRemote!.sid, 1, reason: 'the last frame stays on the stage');
          final before = openCount(t);
          a.elapse(const Duration(seconds: 3));
          expect(ended, 0, reason: 'the hub never said closed: it waits');
          a.elapse(const Duration(seconds: 1));
          expect(ended, 1, reason: 'at most 4 s');
          a.elapse(const Duration(seconds: 60));
          expect(openCount(t), before, reason: 'no automatic try while in the background');
          expect(hints, isEmpty);
        });
      });

      test('background ends the background time once the hub closed every sid', () {
        env((a, t, port, st, hints) {
          hubCloses(t);
          var began = 0, ended = 0;
          unawaited(st.enterBackground(begin: () async => began++, end: () async => ended++));
          a.flushMicrotasks();
          expect((began, ended), (1, 1));
          expect(st.hub!.sessions, isEmpty);
        }, sessions: 2);
      });

      test('shown again before the background time began: nothing closes, presence keeps going', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(1, [rw(3)]));
          final began = Completer<void>();
          var ended = 0;
          unawaited(st.enterBackground(begin: () => began.future, end: () async => ended++));
          a.flushMicrotasks();
          unawaited(st.enterForeground());
          a.flushMicrotasks();
          began.complete();
          a.elapse(const Duration(seconds: 5));
          expect(t.sent.where((m) => m['cmd'] == 'close'), isEmpty);
          expect(t.sent.where((m) => m['cmd'] == 'presence' && m['paused'] == true), isEmpty);
          final r = st.recordFor('111/a')!;
          expect(r.phase, Phase.live);
          expect(r.frozen, false);
          expect(st.backgrounded, false);
          expect(ended, 1, reason: 'the background time still ends');
        });
      });

      test('a dead hub: background and foreground neither throw nor hang', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(1, [rw(3)]));
          unawaited(t.die());
          a.flushMicrotasks();
          var ended = 0;
          Object? error;
          st.enterBackground(end: () async => ended++).catchError((Object e) => error = e);
          a.flushMicrotasks();
          expect(ended, 1);
          st.enterForeground().catchError((Object e) => error = e);
          a.elapse(const Duration(seconds: 5));
          expect(error, isNull);
          expect(st.backgrounded, false);
        });
      });

      test('foreground reconnects current first then others staggered', () {
        env((a, t, port, st, hints) {
          hubCloses(t);
          port.emit(WindowsEvent(1, [rw(3)]));
          port.emit(WindowsEvent(2, [rw(4)]));
          st.select('111/aa'); // B
          unawaited(st.enterBackground());
          a.elapse(const Duration(seconds: 5));
          expect(st.recordFor('111/a')!.frozen && st.recordFor('111/aa')!.frozen, true);
          final n = t.sent.length;
          unawaited(st.enterForeground());
          a.flushMicrotasks();
          List<Map<String, dynamic>> sent() => t.sent.skip(n).toList();
          List<String> opened() => [for (final m in sent()) if (m['cmd'] == 'open') m['app'] as String];
          expect(st.backgrounded, false);
          expect(sent().take(2), [
            {'cmd': 'net_changed'},
            {'cmd': 'presence', 'paused': false},
          ]);
          expect(opened(), ['aa']);
          a.elapse(const Duration(milliseconds: 299));
          expect(opened(), ['aa']);
          a.elapse(const Duration(milliseconds: 1));
          expect(opened(), ['aa', 'a']);
          expect(sent().where((m) => m['cmd'] == 'open').every((m) => m['reconnect'] == true), true);
          a.elapse(const Duration(seconds: 60));
          expect(opened(), ['aa', 'a']);
        }, sessions: 2);
      });

      test('draft survives background round trip', () {
        env((a, t, port, st, hints) {
          hubCloses(t);
          port.emit(WindowsEvent(1, [rw(3)]));
          st.remote[1]!.composer.setDraft('半句');
          unawaited(st.enterBackground());
          a.elapse(const Duration(seconds: 5));
          expect(st.remote[1]!.composer.draft, '半句');
          unawaited(st.enterForeground());
          a.flushMicrotasks();
          expect(st.currentReconnecting, true);
          port.emit(WindowsEvent(11, [rw(3)]));
          expect(st.currentRemote!.sid, 11);
          expect(st.remote[11]!.composer.draft, '半句');
          expect(st.recordFor('111/a')!.frozen, false);
        });
      });

      test('foreground while opening does not open twice', () {
        env((a, t, port, st, hints) {
          hubCloses(t);
          port.emit(WindowsEvent(1, [rw(3)]));
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          final answer = t.onSend;
          final held = <Map<String, dynamic>>[];
          t.onSend = (m) => m['cmd'] == 'open' ? held.add(m) : answer?.call(m);
          st.reconnect('111/a');
          a.flushMicrotasks();
          expect(st.recordFor('111/a')!.phase, Phase.connecting);
          unawaited(st.enterBackground());
          a.elapse(const Duration(seconds: 5));
          final r = st.recordFor('111/a')!;
          expect(r.phase, Phase.disconnected);
          expect(r.frozen, true);
          unawaited(st.enterForeground());
          a.flushMicrotasks();
          expect(held, hasLength(2), reason: 'one open after coming back');
          // The try from before the background answers late: it is closed, never started, and the record is
          // the new try's.
          t.emit(embedOpened(21, held.first['req']));
          a.flushMicrotasks();
          expect(t.sent.last, {'cmd': 'close', 'sid': 21, 'reason': 'background'});
          expect(port.calls.where((c) => c.$1 == 'start' && c.$2['sid'] == 21), isEmpty);
          expect(r.phase, Phase.connecting);
          t.emit(embedOpened(22, held.last['req']));
          a.flushMicrotasks();
          expect(port.calls.where((c) => c.$1 == 'start').map((c) => c.$2['sid']).toList(), [1, 22]);
          port.emit(WindowsEvent(22, [rw(3)]));
          expect(st.currentRemote!.sid, 22);
          a.elapse(const Duration(seconds: 60));
          expect(held, hasLength(2));
          expect(st.sessionCount, 1);
        });
      });

      test('an open answered while in the background is closed at once and never started', () {
        env((a, t, port, st, hints) {
          hubCloses(t);
          port.emit(WindowsEvent(1, [rw(3)]));
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          final answer = t.onSend;
          final held = <Map<String, dynamic>>[];
          t.onSend = (m) => m['cmd'] == 'open' ? held.add(m) : answer?.call(m);
          st.reconnect('111/a');
          a.flushMicrotasks();
          unawaited(st.enterBackground());
          a.flushMicrotasks();
          t.emit(embedOpened(21, held.single['req']));
          a.flushMicrotasks();
          expect(t.sent.last, {'cmd': 'close', 'sid': 21, 'reason': 'background'});
          expect(port.calls.where((c) => c.$1 == 'start' && c.$2['sid'] == 21), isEmpty);
          expect(st.recordFor('111/a')!.phase, Phase.disconnected);
          expect(st.currentRemote!.sid, 1);
          a.elapse(const Duration(seconds: 60));
          expect(held, hasLength(1));
        });
      });

      test('a late event of the closed sid brings nothing back and nothing goes to it', () {
        env((a, t, port, st, hints) {
          hubCloses(t);
          port.emit(WindowsEvent(1, [rw(3)]));
          unawaited(st.enterBackground());
          a.elapse(const Duration(seconds: 5));
          final hubSent = t.sent.length, portSent = port.calls.length;
          port.emit(WindowsEvent(1, [rw(3), rw(4)]));
          port.emit(const TrafficEvent(1, 100, 1));
          port.emit(const ScreenLockedEvent(1, true));
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          a.flushMicrotasks();
          final r = st.recordFor('111/a')!;
          expect(r.phase, Phase.disconnected);
          expect(disconnectWord(r.reason), '切到后台');
          st.remote[1]!.composer.setDraft('x');
          st.selectWindow(4);
          a.elapse(const Duration(seconds: 60));
          expect(t.sent.skip(hubSent), isEmpty);
          expect(port.calls.skip(portSent).where((c) => c.$2['sid'] == 1), isEmpty);
        });
      });

      test('memory warning drops the pictures of frozen sessions only, not the one on the stage', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(1, [rw(3)]));
          port.emit(WindowsEvent(2, [rw(4)]));
          port.emit(WindowsEvent(3, [rw(5)]));
          st.select('111/aaa');
          port.emit(const DisconnectedEvent(1, 'connection closed'));
          port.emit(const DisconnectedEvent(3, 'connection closed'));
          a.flushMicrotasks();
          st.memoryWarning();
          expect([for (final c in port.calls) if (c.$1 == 'drop_textures') c.$2['sid']], [1]);
        }, sessions: 3);
      });

      test('stageLive: a live session on the stage, not 全景, not in the background (§9.5)', () {
        env((a, t, port, st, hints) {
          port.emit(WindowsEvent(1, [rw(3)]));
          expect(st.stageLive, true);
          st.overview = true;
          expect(st.stageLive, false);
          st.overview = false;
          unawaited(st.enterBackground());
          a.flushMicrotasks();
          expect(st.stageLive, false);
        });
      });

      test('reconnect auto-unlocks when A locked and password remembered', () {
        final store = UnlockStore(memory: true);
        env((a, t, port, st, hints) {
          unawaited(store.save('111', 'pw', auto: true));
          a.flushMicrotasks();
          hubCloses(t);
          port.emit(WindowsEvent(1, [rw(3)]));
          port.emit(const ScreenLockedEvent(1, false));
          unawaited(st.enterBackground());
          a.elapse(const Duration(seconds: 5));
          unawaited(st.enterForeground());
          a.flushMicrotasks();
          port.emit(const ScreenLockedEvent(11, true));
          a.flushMicrotasks();
          expect([for (final c in port.calls) if (c.$1 == 'unlock') c.$2], [
            {'sid': 11, 'password': 'pw'},
          ]);
        }, unlockStore: store);
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
      a.flushMicrotasks();
      st.toggleDetach();
      a.flushMicrotasks();
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

    test('raiseIfDetached raises a live detached session and leaves the current one alone', () {
      env((a, t, port, st, hints) {
        port.emit(const DetachedEvent(1, true));
        a.flushMicrotasks();
        final before = st.currentKey;
        expect(st.raiseIfDetached('111/a'), isTrue);
        lastCall(port, 'raise_detached', {'sid': 1});
        expect(st.currentKey, before);
      });
    });

    test('raiseIfDetached is false for an attached, disconnected or unknown session', () {
      env((a, t, port, st, hints) {
        final calls = port.calls.length;
        expect(st.raiseIfDetached('111/a'), isFalse); // attached
        expect(st.raiseIfDetached('999/x'), isFalse); // unknown
        port.emit(const DetachedEvent(1, true));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        a.flushMicrotasks();
        expect(st.remote[1]!.detached, isTrue);
        expect(st.raiseIfDetached('111/a'), isFalse); // disconnected
        expect(port.calls.skip(calls).where((c) => c.$1 == 'raise_detached'), isEmpty);
      });
    });

    test('native sends enter the shared queue exactly once and retry its failed remainder', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        port.emit(const DetachedEvent(1, true));
        port.emit(const ComposerDraftEvent(1, text: 'native words', send: true));
        a.flushMicrotasks();
        expect(port.calls.where((c) => c.$1 == 'composer_send'), hasLength(1));
        final model = st.remote[1]!.composer;
        expect(model.draft, '');
        expect(model.inFlight!.text, 'native words');
        port.emit(const ComposerStateEvent(1, done: ComposerDone(0, 'refused')));
        expect(model.failed.single.text, 'native words');
        port.emit(const ComposerDraftEvent(1, retry: true));
        a.flushMicrotasks();
        expect(port.calls.where((c) => c.$1 == 'composer_send'), hasLength(2));
        port.emit(const ComposerStateEvent(1, done: ComposerDone(1, null)));
        expect(model.failed, isEmpty);
        expect(model.sending, false);
      });
    });

    test('disconnect during a native submit keeps the taken text as a failed send', () {
      env((a, t, port, st, hints) {
        final editor = _DelayedTakeEditor();
        final model = st.remote[1]!.composer;
        model.attach(editor);
        port.emit(const ComposerDraftEvent(1, text: 'not sent', send: true));
        a.flushMicrotasks();
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        editor.gate.complete();
        a.flushMicrotasks();
        expect(port.calls.where((c) => c.$1 == 'composer_send'), isEmpty);
        expect(model.sending, false);
        expect(model.failed.single.text, 'not sent');
      });
    });

    test('native local edits during reconnect survive the sid swap and never send', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(3)]));
        port.emit(const DetachedEvent(1, true));
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        st.reconnect('111/a');
        a.flushMicrotasks();
        port.emit(const ComposerDraftEvent(1, text: 'written offline', send: true));
        expect(st.remote[1]!.composer.draft, 'written offline');
        expect(port.calls.where((c) => c.$1 == 'composer_send'), isEmpty);
        port.emit(WindowsEvent(11, [rw(3)]));
        a.flushMicrotasks();
        expect(st.remote[11]!.composer.draft, 'written offline');
      });
    });

    test('detach waits for an already requested clipboard or file insertion', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        final model = st.remote[1]!.composer;
        final editor = FakeEditor();
        model.attach(editor);
        editor.value = 'before ';
        final result = Completer<PasteResult>();
        model.applyPending(result.future);
        st.detach();
        a.flushMicrotasks();
        expect(port.calls.where((c) => c.$1 == 'detach'), isEmpty);
        result.complete(const PasteResult(text: 'late paste', blocks: [BlockChip(3, 'file')]));
        a.flushMicrotasks();
        lastCall(port, 'detach', {'sid': 1, 'text': 'before late paste', 'blocks': [{'n': 3, 'label': 'file'}]});
      });
    });

    test('detach and attach keep the sid and send no open', () {
      env((a, t, port, st, hints) {
        port.emit(const ReadyEvent(1, 'Calculator'));
        port.emit(WindowsEvent(1, [rw(7), rw(9, kind: WindowKind.menu)]));
        st.toggleDetach();
        a.flushMicrotasks();
        lastCall(port, 'detach', {'sid': 1, 'text': '', 'blocks': []});
        expect(st.currentRemote!.detached, false); // only the runner's word moves it
        port.emit(const DetachedEvent(1, true));
        expect(st.currentRemote!.detached, true);
        expect(t.sent.last, {'cmd': 'note', 'sid': 1, 'what': 'detach', 'windows': 1});
        st.toggleDetach();
        a.flushMicrotasks();
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
        a.flushMicrotasks();
        lastCall(port, 'detach', {'sid': 1, 'text': '', 'blocks': []});
        st.attach();
        lastCall(port, 'attach', {'sid': 1});
        st.select('111/aa');
        st.toggleDetach();
        a.flushMicrotasks();
        lastCall(port, 'detach', {'sid': 2, 'text': '', 'blocks': []});
        // Nothing to move yet (no window table): no detach goes out.
        port.emit(const WindowsEvent(2, []));
        final n = port.calls.length;
        st.detach();
        a.flushMicrotasks();
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

    test('composerKey: closed → open with the caret; picture → caret; editor → picture, panel stays', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        final c = st.currentRemote!.composer;
        expect(c.open, false);
        final focus0 = c.focusTick;
        st.composerKey();
        expect(c.open, true);
        expect(c.focusTick, focus0 + 1);

        // Open, the caret not in the editor (the picture has the keys): the caret comes back.
        st.focusPicture(1);
        c.editorFocused = false;
        st.composerKey();
        expect(c.focusTick, focus0 + 2);
        expect(c.open, true);

        // The caret in the editor: it goes to the picture, the panel stays.
        c.editorFocused = true;
        st.pictureFocused = null;
        final release0 = c.releaseTick;
        st.composerKey();
        expect(c.releaseTick, release0 + 1);
        expect(st.pictureFocused, 1);
        expect(c.open, true);
        lastCall(port, 'picture_focus', {'sid': 1, 'compose': true});
      });
    });

    test('composerKey from the editor on a detached stage only lets go of the editor', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        port.emit(const DetachedEvent(1, true));
        final c = st.currentRemote!.composer;
        c.open = true;
        c.editorFocused = true;
        final release0 = c.releaseTick;
        st.composerKey();
        expect(c.releaseTick, release0 + 1);
        expect(st.pictureFocused, isNull);
      });
    });

    test('composerKey does nothing in the overview', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        final c = st.currentRemote!.composer;
        st.toggleOverview();
        expect(st.overview, true);
        st.composerKey();
        expect(c.open, false);
        expect(c.focusTick, 0);
      });
    });

    test('composerKey does nothing without a session or when composerAllowed is false', () {
      env((a, t, port, st, hints) {
        st.composerKey(); // no session: no throw
      }, sessions: 0);
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        final rs = st.currentRemote!;
        rs.setProfile(const ResolvedProfile(composer: false));
        expect(rs.composerAllowed, false);
        st.composerKey();
        expect(rs.composer.open, false);
        expect(rs.composer.focusTick, 0);
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

    test('focusPicture sends compose for an app picture, not when typeToCompose is off or noComposer', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        st.focusPicture(1);
        lastCall(port, 'picture_focus', {'sid': 1, 'compose': true});
      });
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        st.currentRemote!.setProfile(const ResolvedProfile(typeToCompose: false));
        st.focusPicture(1);
        lastCall(port, 'picture_focus', {'sid': 1});
      });
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        st.currentRemote!.setProfile(const ResolvedProfile(composer: false));
        st.focusPicture(1);
        lastCall(port, 'picture_focus', {'sid': 1});
      });
    });

    test('a profile change re-sends compose to the focused picture, once', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        st.focusPicture(1);
        final rs = st.currentRemote!;
        int sends() => port.calls.where((c) => c.$1 == 'picture_focus').length;
        final n0 = sends();
        rs.setProfile(const ResolvedProfile(typeToCompose: false));
        lastCall(port, 'picture_focus', {'sid': 1});
        expect(sends(), n0 + 1);
        rs.setProfile(const ResolvedProfile(typeToCompose: false, recordInput: false));
        expect(sends(), n0 + 1); // unchanged: nothing re-sent
        rs.setProfile(const ResolvedProfile());
        lastCall(port, 'picture_focus', {'sid': 1, 'compose': true});
        expect(sends(), n0 + 2);
        st.blurPicture();
        final n1 = sends();
        rs.setProfile(const ResolvedProfile(typeToCompose: false));
        expect(sends(), n1); // not focused: nothing to re-send
      });
    });

    test('a letter-opened panel closed unused sends compose:false; the user opening the panel sends it true again', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        st.focusPicture(1);
        lastCall(port, 'picture_focus', {'sid': 1, 'compose': true});
        final rs = st.currentRemote!;
        port.emit(const ComposeKeyEvent(1));
        expect(rs.composer.open, true);
        rs.composer.collapse();
        expect(rs.composeArmed, false);
        lastCall(port, 'picture_focus', {'sid': 1});
        st.composerKey(); // the user's own open (Ctrl+Enter)
        expect(rs.composeArmed, true);
        lastCall(port, 'picture_focus', {'sid': 1, 'compose': true});
      });
    });

    test('a tab switch to a noComposer window re-sends compose:false, and back', () {
      env((a, t, port, st, hints) {
        port.emit(WindowsEvent(1, [rw(7)]));
        final rs = st.currentRemote!;
        rs.setProfile(const ResolvedProfile(windows: [WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer)]));
        st.focusPicture(1);
        lastCall(port, 'picture_focus', {'sid': 1, 'compose': true});
        port.emit(WindowsEvent(1, [rw(7), rw(8, kind: WindowKind.dialog)])); // 8 is new: current
        lastCall(port, 'picture_focus', {'sid': 1});
        rs.selectWindow(7);
        lastCall(port, 'picture_focus', {'sid': 1, 'compose': true});
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
          expect(port.calls.where((c) => c.$1 == 'picture_focus').last.$2, {'sid': 11, 'compose': true});
        });
      });

      test('a session detached before the move is still detached after the swap', () {
        move((a, t, port, st, hints, reopens) {
          st.select('111/a');
          port.emit(const DetachedEvent(1, true));
          st.remote[1]!.composer.setDraft('retained draft');
          a.flushMicrotasks();
          path(a, t, 'lan');
          answer(a, t, reopens[0], 11, 'lan');
          picture(a, port, 11);
          expect(st.recordFor('111/a')!.sid, 11);
          expect(port.calls.where((c) => c.$1 == 'detach').last.$2, {'sid': 11, 'text': 'retained draft', 'blocks': []});
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
          a.flushMicrotasks();
          expect(port.calls.last.$1, 'detach');
          expect(port.calls.last.$2, {'sid': 1, 'text': '', 'blocks': []});
          port.emit(const DetachedEvent(1, true));
          a.flushMicrotasks();
          expect(t.sent.any((m) => m['cmd'] == 'note' && m['sid'] == 1 && m['what'] == 'detach'), true);
          expect(st.pictureFocused, isNull);
          picture(a, port, 11);
          expect(port.calls.where((c) => c.$1 == 'detach').last.$2, {'sid': 11, 'text': '', 'blocks': []});
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

  group('input record', () {
    late DataDir d;
    const key = '111/com.a';
    final sid = 'com.a'.length;

    setUp(() {
      d = DataDir(tmp.path);
      Directory(d.localDir).createSync(recursive: true);
      File('${d.localDir}/service.json').writeAsStringSync('{"id":"dev1"}');
      Directory(d.deviceDir('dev1')).createSync(recursive: true);
      File('${d.deviceDir('dev1')}/device.json').writeAsStringSync('{"name":"bruce-tablet"}');
    });

    DraftStore drafts() => DraftStore(() => d.draftsDir);

    List<Map<String, Object?>> lines() {
      final dir = Directory(d.inputsDir('dev1'));
      if (!dir.existsSync()) return [];
      return [
        for (final f in dir.listSync().whereType<File>())
          for (final l in f.readAsLinesSync())
            if (l.isNotEmpty) (jsonDecode(l) as Map).cast<String, Object?>(),
      ];
    }

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 200 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));

    RemoteWindow win(int id) => RemoteWindow(
          id: id,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w$id',
          rect: const Rect.fromLTWH(0, 0, 400, 328),
          titleBar: 28,
          resizable: true,
          focused: false,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    // A MainState with its own hub and port; an open answers sid = the app's length (+10 per
    // reconnect). It has opened com.a on 111 when this returns (unless [live] is false).
    // [reopen]: a reconnect's open waits for it to call `answer`.
    Future<(MainState, FakeSessionPort)> start(
        {UiPrefs? prefs,
        AppProfileStore? profiles,
        void Function(void Function() answer)? reopen,
        Object? startError,
        bool live = true}) async {
      final t = FakeTransport();
      final port = FakeSessionPort()..startError = startError;
      final h = HubClient(t);
      t.emit({
        'event': 'hosts',
        'hosts': [
          {'id': '111', 'name': 'mini'},
        ],
      });
      await pump();
      final st = MainState(hub: h, data: d, prefs: prefs ?? UiPrefs(), port: port, profiles: profiles);
      var reconnects = 0;
      t.onSend = (m) {
        if (m['cmd'] != 'open') return;
        final n = (m['app'] as String).length + (m['reconnect'] == true ? 10 * ++reconnects : 0);
        void answer() =>
            t.emit({...opened(n, '111', m['app'] as String), 'port': 5000 + n, 'token': 'tk', 'req': m['req']});
        if (m['reconnect'] == true && reopen != null) {
          reopen(answer);
        } else {
          answer();
        }
      };
      await st.openOrSwitch('111', 'com.a', 'A');
      if (live) await until(() => st.currentRemote != null);
      return (st, port);
    }

    test('a send to a session is recorded with what MainState knows of it', () async {
      final (st, port) = await start();
      st.workspace.projects.add(Project('p1', 'rapp', [Member(AppRef('111', 'com.a', 'A'))]));
      port.emit(WindowsEvent(sid, [win(3)]));
      final rs = st.currentRemote!;
      rs.composer.setDraft('你好');
      await rs.composer.submit();
      rs.composer.done(1, null);
      await until(() => lines().length == 1);
      final r = lines().single;
      expect(r['host'], {'id': '111', 'name': 'mini'});
      expect(r['app'], {'id': 'com.a', 'name': 'A'});
      expect(r['session'], key);
      expect(r['run'], st.recordFor(key)!.run);
      expect((r['run'] as String).length, 26);
      expect(r['window'], {'id': 3, 'title': 'w3'});
      expect(r['projects'], ['rapp']);
      expect(r['from'], {'id': 'dev1', 'name': 'bruce-tablet'});
    });

    test('a written record is in its session\'s recall at once (R2)', () async {
      final (st, _) = await start();
      final rs = st.currentRemote!;
      expect(st.recallOf(rs), isEmpty);
      rs.composer.setDraft('上一条');
      await rs.composer.submit();
      expect(st.recallOf(rs).map((e) => e.text), ['上一条'], reason: 'in memory from the handoff on');
      rs.composer.done(1, null);
      await until(() => st.recallOf(rs).single.mine);
      expect(st.recallOf(rs).map((e) => e.text), ['上一条']);
      expect(st.history.forSession(key).single.session, key);
    });

    test('with the record off, up still brings back what this run sent (R2)', () async {
      final (st, _) = await start(prefs: UiPrefs(inputHistory: false));
      final rs = st.currentRemote!;
      rs.composer.setDraft('只在内存');
      await rs.composer.submit();
      rs.composer.done(1, null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(st.recallOf(rs).map((e) => e.text), ['只在内存']);
      expect(st.history.search(''), isEmpty);
      rs.composer.setDraft('写了一半');
      expect(rs.composer.arrow(true), true);
      await Future<void>.delayed(Duration.zero);
      expect(rs.composer.draft, '只在内存');
    });

    test('the records on disk are read at start, from every device', () async {
      final f = File('${d.inputsDir('dev2')}/2026-11-14.jsonl');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('${jsonEncode({
        'v': 1, 'id': '01A', 'ts': '2026-11-14T10:00:00+09:00', 'kind': 'draft',
        'from': {'id': 'dev2', 'name': 'other'}, 'host': {'id': '111', 'name': 'mini'},
        'app': {'id': 'com.a', 'name': 'A'}, 'session': key, 'run': 'r', 'projects': <String>[],
        'text': '别处写的', 'blocks': <Object>[], 'source': 'typed',
      })}\n{"v":1,\n');
      final (st, _) = await start();
      final rs = st.currentRemote!;
      await until(() => st.recallOf(rs).isNotEmpty);
      expect(st.recallOf(rs).single.text, '别处写的');
      expect(st.recallOf(rs).single.mine, isFalse);
    });

    test('a send cut off by a crash comes back on the next open', () async {
      final (st, _) = await start();
      final rs = st.currentRemote!;
      rs.composer.setDraft('断在半路');
      await rs.composer.submit();
      await until(() => drafts().load(key)?.pending.isNotEmpty ?? false);
      // Killed: no done, no dispose.
      final (st2, _) = await start();
      expect(st2.currentRemote!.composer.draft, '断在半路');
    });

    test('a reconnect does not restore the draft twice and keeps the unwritten record', () async {
      await drafts().save(DraftFile(key: key, text: '草稿'));
      File(d.inputsDir('dev1')).writeAsStringSync('in the way'); // the failed round's record waits
      final (st, port) = await start();
      port.emit(WindowsEvent(sid, [win(3)]));
      final old = st.currentRemote!;
      expect(old.composer.draft, '草稿');
      await old.composer.submit();
      old.composer.setDraft('还在写');
      port.emit(DisconnectedEvent(sid, 'boom'));
      await settle();
      var f = drafts().load(key)!;
      expect(f.pending, isEmpty);
      expect([for (final r in f.records) (r['text'], r['result'])], [('草稿', 'failed')]);
      await st.reconnect(key);
      await pump();
      port.emit(WindowsEvent(sid + 10, [win(3)]));
      await settle();
      final fresh = st.currentRemote!;
      expect(fresh.sid, sid + 10);
      expect(fresh.composer.draft, '还在写');
      expect(fresh.composer.failed.map((o) => o.text), ['草稿']);
      f = drafts().load(key)!;
      expect(f.text, '还在写');
      expect(f.pending, isEmpty);
      expect(f.records.map((r) => r['text']), ['草稿'], reason: 'the swap drops nothing');
      // Writable again: the end writes the kept record, then the draft.
      File(d.inputsDir('dev1')).deleteSync();
      st.endCurrent();
      port.emit(ClosedEvent(sid + 10, 'rapp-client: quit'));
      await until(() => lines().length == 2);
      expect([for (final r in lines()) (r['kind'], r['text'])], [('sent', '草稿'), ('draft', '还在写')]);
      await until(() => drafts().load(key) == null);
      expect(drafts().load(key), isNull);
    });

    test('a row still in flight at the swap follows to the new session, pending once', () async {
      final (st, port) = await start();
      port.emit(WindowsEvent(sid, [win(3)]));
      final old = st.currentRemote!;
      port.emit(DisconnectedEvent(sid, 'boom'));
      await settle();
      // Stands in for a move's send, whose done never comes: the swap is the same `_dropOld`.
      old.composer.setDraft('在路上');
      await old.composer.submit();
      await until(() => drafts().load(key)?.pending.isNotEmpty ?? false);
      await st.reconnect(key);
      await pump();
      port.emit(WindowsEvent(sid + 10, [win(3)]));
      await settle();
      final fresh = st.currentRemote!;
      expect(fresh.sid, sid + 10);
      expect(fresh.composer.retry(fresh.composer.failed.single), isNotNull);
      await settle();
      expect(drafts().load(key)!.pending, ['在路上'], reason: 'once');
      fresh.composer.done(1, null);
      await until(() => lines().length == 1 && drafts().load(key) == null);
      expect(lines().single['text'], '在路上');
      expect(lines().single['result'], 'sent');
    });

    test("the old session's close before the reopen answers drops nothing", () async {
      File(d.inputsDir('dev1')).writeAsStringSync('in the way');
      void Function()? answer;
      final (st, port) = await start(reopen: (a) => answer = a);
      port.emit(WindowsEvent(sid, [win(3)]));
      final old = st.currentRemote!;
      old.composer.setDraft('断在路上');
      await old.composer.submit();
      port.emit(DisconnectedEvent(sid, 'boom'));
      await settle();
      final reconnected = st.reconnect(key); // waits for the open's answer
      await pump();
      expect(answer, isNotNull);
      port.emit(ClosedEvent(sid, 'gone')); // no fresh session to take the old one's rows
      await settle();
      expect(st.remote.containsKey(sid), false);
      expect(drafts().load(key)!.records.map((r) => r['text']), ['断在路上']);
      File(d.inputsDir('dev1')).deleteSync();
      answer!();
      await reconnected;
      await until(() => st.currentRemote?.sid == sid + 10);
      await until(() => lines().length == 1);
      expect(lines().single['text'], '断在路上');
      expect(lines().single['result'], 'failed');
      expect(st.currentRemote!.composer.draft, '', reason: 'a finished round is no draft');
    });

    test('ending a session that never went live turns its draft into a draft record', () async {
      await drafts().save(DraftFile(key: key, text: '上次的'));
      final (st, _) = await start(startError: 'boom', live: false);
      await until(() => st.recordFor(key)?.phase == Phase.disconnected);
      expect(st.remote, isEmpty);
      st.endCurrent();
      await until(() => lines().length == 1);
      expect(lines().single['kind'], 'draft');
      expect(lines().single['text'], '上次的');
      await until(() => drafts().load(key) == null);
      expect(drafts().load(key), isNull);
    });

    test('ending a session turns its draft into a draft record; disconnecting does not', () async {
      final (st, port) = await start();
      st.currentRemote!.composer.setDraft('没发的');
      await until(() => drafts().load(key)?.text == '没发的');
      port.emit(DisconnectedEvent(sid, 'boom'));
      await settle();
      expect(lines(), isEmpty);
      expect(drafts().load(key)!.text, '没发的');
      st.endCurrent();
      await until(() => lines().length == 1);
      final r = lines().single;
      expect(r['kind'], 'draft');
      expect(r['text'], '没发的');
      expect(r['session'], key);
      expect(r['host'], {'id': '111', 'name': 'mini'});
      await until(() => drafts().load(key) == null);
      expect(drafts().load(key), isNull);
    });

    test('drafts older than 7 days become draft records at start', () async {
      final meta = SessionMeta(
          key: '111/com.old', hostId: '111', hostName: 'mini', appId: 'com.old', appName: 'Old', run: 'r0', projects: []);
      await drafts().save(DraftFile(key: '111/com.old', text: '一周前', meta: {...meta.toJson(), 'record': true}));
      File(drafts().pathFor('111/com.old')).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
      await start();
      await until(() => lines().length == 1);
      final r = lines().single;
      expect(r['kind'], 'draft');
      expect(r['text'], '一周前');
      expect(r['session'], '111/com.old');
      await until(() => drafts().load('111/com.old') == null);
      expect(drafts().load('111/com.old'), isNull);
    });

    test('the overall switch and the app switch keep sends out of the record', () async {
      for (final off in ['inputHistory', 'recordInput']) {
        final (st, port) = await start(
            prefs: UiPrefs(inputHistory: off != 'inputHistory'),
            profiles: AppProfileStore('${tmp.path}/shared',
                builtin: [AppProfile(ids: ['com.a'], name: 'A', recordInput: off != 'recordInput')]));
        final rs = st.currentRemote!;
        rs.composer.setDraft('不记');
        await rs.composer.submit();
        rs.composer.done(1, null);
        rs.composer.setDraft('留着');
        await settle();
        expect(Directory(d.inputsDir('dev1')).existsSync(), false, reason: off);
        st.endCurrent();
        port.emit(ClosedEvent(sid, 'rapp-client: quit'));
        await settle();
        expect(st.recordFor(key), isNull, reason: off);
        expect(drafts().load(key)!.text, '留着', reason: off);
        await drafts().delete(key);
        st.dispose();
      }
    });
  });

  group('working spheres', () {
    late DateTime now;
    setUp(() => now = DateTime(2026, 11, 15, 9));

    MainState make({UiPrefs? prefs}) {
      final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: prefs ?? UiPrefs(), clock: () => now);
      addTearDown(st.dispose);
      return st;
    }

    Project project(MainState st, String name, List<String> bundles) {
      final p = st.createProject(name)!;
      for (final b in bundles) {
        st.addMember(p.id, AppRef('111', b, b));
      }
      return p;
    }

    Future<void> open(List<String> bundles, {int from = 1}) async {
      for (final (i, b) in bundles.indexed) {
        t.emit(opened(from + i, '111', b));
      }
      await pump();
    }

    /// Inside fakeAsync: an embedded MainState with sessions 111/a, 111/aa, 111/aaa (sids 1, 2, 3) open.
    (FakeSessionPort, MainState) embedded(FakeAsync a) {
      final t = FakeTransport();
      final hub = HubClient(t);
      final port = FakeSessionPort();
      final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, clock: () => now);
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
      for (final b in ['a', 'aa', 'aaa']) {
        st.openOrSwitch('111', b, b);
        a.flushMicrotasks();
      }
      return (port, st);
    }

    test('switching lands on the session last used in that project', () async {
      final st = make();
      await open(['com.a', 'com.b', 'com.q']);
      final p = project(st, 'P', ['com.a', 'com.b']);
      final q = project(st, 'Q', ['com.q']);
      st.switchProject(p.id);
      expect(st.currentProject, p.id);
      expect(st.currentKey, '111/com.a');
      expect(st.grouping, Grouping.project);
      expect(st.groups.first.projectId, p.id);
      st.select('111/com.b');
      expect(st.currentProject, p.id);
      st.switchProject(q.id);
      expect(st.currentKey, '111/com.q');
      expect(st.groups.first.projectId, q.id);
      st.switchProject(p.id);
      expect(st.currentKey, '111/com.b');
      expect(st.currentProject, p.id);
    });

    test('switching away records when and where, and it survives a restart', () async {
      final st = make();
      await open(['com.a', 'com.b']);
      final p = project(st, 'P', ['com.a', 'com.b']);
      final q = project(st, 'Q', []);
      st.switchProject(p.id);
      st.select('111/com.b');
      now = now.add(const Duration(minutes: 25));
      st.switchProject(q.id);
      final again = make();
      final pos = again.positions.byProject[p.id]!;
      expect(pos.last, '111/com.b');
      expect(pos.leftAt!.isAtSameMomentAs(now), isTrue);
    });

    test('the session last used in a project survives a restart while still in it', () {
      fakeAsync((a) {
        final (_, st) = embedded(a);
        final p = project(st, 'P', ['a', 'aa']);
        st.switchProject(p.id);
        expect(st.currentKey, '111/a');
        st.select('111/aa');
        a.elapse(MainState.positionsSaveDelay);
        expect(ProjectPositions.load(DataDir(tmp.path).localDir).byProject[p.id]!.last, '111/aa');
        // Quit while in P (no leave is recorded), start again, 切到 P.
        final (_, again) = embedded(a);
        again.switchProject(p.id);
        expect(again.currentKey, '111/aa');
        st.dispose();
        again.dispose();
      });
    });

    test('a pending position save is written on dispose and leaves no timer', () {
      fakeAsync((a) {
        final (_, st) = embedded(a);
        final p = project(st, 'P', ['a', 'aa']);
        st.switchProject(p.id);
        st.select('111/aa');
        st.dispose();
        expect(a.pendingTimers.where((t) => t.duration == MainState.positionsSaveDelay), isEmpty);
        expect(ProjectPositions.load(DataDir(tmp.path).localDir).byProject[p.id]!.last, '111/aa');
      });
    });

    test('a leave that was not recorded shows no cue rather than one counted from an older leave', () {
      final st = make();
      final p = project(st, 'P', []);
      final q = project(st, 'Q', []);
      st.switchProject(p.id);
      st.switchProject(q.id); // Monday: left P
      now = now.add(const Duration(days: 1));
      st.switchProject(p.id); // Tuesday: works in P and quits while in it
      expect(st.cue, '1 天前离开');
      expect(ProjectPositions.load(DataDir(tmp.path).localDir).byProject[p.id]!.leftAt, isNull);
      now = now.add(const Duration(days: 1));
      final again = make(); // Wednesday
      again.switchProject(p.id);
      expect(again.cue, '');
    });

    test('coming back shows the cue for five seconds', () {
      fakeAsync((a) {
        final st = make();
        final p = project(st, 'P', []);
        final q = project(st, 'Q', []);
        var n = 0;
        st.addListener(() => n++);
        st.switchProject(p.id);
        st.switchProject(q.id);
        now = now.add(const Duration(minutes: 25));
        st.switchProject(p.id);
        expect(st.cue, '25 分钟前离开');
        a.elapse(MainState.cueFor - const Duration(milliseconds: 1));
        expect(st.cue, '25 分钟前离开');
        final before = n;
        a.elapse(const Duration(milliseconds: 1));
        expect(st.cue, '');
        expect(n, before + 1);
        // A new cue replaces the old one, and its own five seconds start over.
        now = now.add(const Duration(minutes: 2));
        st.switchProject(q.id);
        expect(st.cue, '2 分钟前离开');
        a.elapse(const Duration(seconds: 3));
        now = now.add(const Duration(minutes: 3));
        st.switchProject(p.id);
        expect(st.cue, '3 分钟前离开');
        a.elapse(const Duration(seconds: 2));
        expect(st.cue, '3 分钟前离开');
        a.elapse(const Duration(seconds: 3));
        expect(st.cue, '');
      });
    });

    test('the cue counts members that went 已断开 while away; ones already so before leaving do not count', () {
      // No session lamp is 等你 yet (recordLamp never gives it), so 已断开 drives the count here;
      // both go through the same _attentionSince bookkeeping.
      fakeAsync((a) {
        final (port, st) = embedded(a);
        final p = project(st, 'P', ['a', 'aa', 'aaa']);
        final q = project(st, 'Q', []);
        st.switchProject(p.id);
        port.emit(const DisconnectedEvent(1, 'connection closed'));
        a.flushMicrotasks();
        now = now.add(const Duration(minutes: 1));
        st.switchProject(q.id);
        now = now.add(const Duration(minutes: 10));
        port.emit(const DisconnectedEvent(2, 'connection closed'));
        a.flushMicrotasks();
        expect(st.entryFor('111/a')!.lamp, Lamp.disconnected);
        expect(st.entryFor('111/aa')!.lamp, Lamp.disconnected);
        expect(st.entryFor('111/aaa')!.lamp, isNot(Lamp.disconnected));
        now = now.add(const Duration(minutes: 20));
        st.switchProject(p.id);
        expect(st.cue, '30 分钟前离开 · 这期间 1 个已断开');
        st.dispose();
      });
    });

    test('first switch to a project has no cue', () {
      final st = make();
      final p = project(st, 'P', []);
      st.switchProject(p.id);
      expect(st.cue, '');
      expect(st.previousProject, isNull);
    });

    test('back to the previous project and back again', () {
      final st = make();
      final p = project(st, 'P', []);
      final q = project(st, 'Q', []);
      st.switchProject(p.id);
      st.switchProject(q.id);
      expect((st.currentProject, st.previousProject), (q.id, p.id));
      st.backToPreviousProject();
      expect((st.currentProject, st.previousProject), (p.id, q.id));
      st.backToPreviousProject();
      expect((st.currentProject, st.previousProject), (q.id, p.id));
    });

    test('backToPreviousProject without one does nothing', () {
      final st = make();
      final p = project(st, 'P', []);
      var n = 0;
      st.addListener(() => n++);
      st.backToPreviousProject();
      expect((st.currentProject, st.previousProject, n), (null, null, 0));
      st.switchProject(p.id);
      n = 0;
      st.backToPreviousProject();
      expect((st.currentProject, st.previousProject, n), (p.id, null, 0));
    });

    test('selecting a session outside the current project leaves the project', () async {
      final st = make();
      await open(['com.a', 'com.z']);
      final p = project(st, 'P', ['com.a']);
      st.switchProject(p.id);
      expect(st.currentKey, '111/com.a');
      now = now.add(const Duration(minutes: 5));
      st.select('111/com.z');
      expect(st.currentKey, '111/com.z');
      expect((st.currentProject, st.previousProject), (null, p.id));
      expect(st.positions.of(p.id).last, '111/com.a');
      expect(st.positions.of(p.id).leftAt!.isAtSameMomentAs(now), isTrue);
      final saved = ProjectPositions.load(DataDir(tmp.path).localDir).byProject[p.id]!;
      expect(saved.last, '111/com.a');
      expect(saved.leftAt!.isAtSameMomentAs(now), isTrue);
      // Back to it from no project: the cue counts from that leave, and there is no other project to go back to.
      now = now.add(const Duration(minutes: 3));
      st.backToPreviousProject();
      expect((st.currentProject, st.previousProject, st.currentKey), (p.id, null, '111/com.a'));
      expect(st.cue, '3 分钟前离开');
    });

    test('a failed open of a session outside the project keeps the project', () async {
      final st = make();
      await open(['com.a']);
      final p = project(st, 'P', ['com.a']);
      st.switchProject(p.id);
      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'offline'});
      };
      await st.openOrSwitch('111', 'com.z', 'Z');
      expect(st.currentKey, '111/com.a');
      expect((st.currentProject, st.previousProject), (p.id, null));
      expect(st.positions.of(p.id).leftAt, isNull);
    });

    test('embedded: a failed open stays on stage (it retries), so the project is left', () {
      fakeAsync((a) {
        final t = FakeTransport();
        final st = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort(), clock: () => now);
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            final ok = m['app'] == 'a';
            t.emit(ok
                ? {'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'port': 5001, 'token': 'tk', 'req': m['req']}
                : {'event': 'error', 'error': 'timed out', 'req': m['req']});
          }
        };
        a.flushMicrotasks();
        st.openOrSwitch('111', 'a', 'a');
        a.flushMicrotasks();
        final p = project(st, 'P', ['a']);
        st.switchProject(p.id);
        st.openOrSwitch('111', 'z', 'z');
        a.flushMicrotasks();
        expect(st.currentKey, '111/z');
        expect(st.recordFor('111/z')!.phase, Phase.disconnected);
        expect((st.currentProject, st.previousProject), (null, p.id));
        st.dispose();
        a.flushTimers();
      });
    });

    test('an open of a session outside the project leaves the project once it opens', () async {
      final st = make();
      await open(['com.a']);
      final p = project(st, 'P', ['com.a']);
      st.switchProject(p.id);
      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit({...opened(9, m['id'] as String, m['app'] as String), 'req': m['req']});
      };
      final opening = st.openOrSwitch('111', 'com.z', 'Z');
      expect(st.currentKey, '111/com.z');
      expect(st.currentProject, p.id, reason: 'still opening');
      await opening;
      expect(st.currentKey, '111/com.z');
      expect((st.currentProject, st.previousProject), (null, p.id));
      expect(st.positions.of(p.id).last, '111/com.a');
    });

    test('「全部打开」 on another project switches to it', () async {
      final st = make();
      await open(['com.a', 'com.q']);
      final p = project(st, 'P', ['com.a']);
      final q = project(st, 'Q', ['com.q', 'com.r']);
      st.switchProject(p.id);
      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit({...opened(9, m['id'] as String, m['app'] as String), 'req': m['req']});
      };
      st.openAll(q.id);
      expect((st.currentProject, st.previousProject), (q.id, p.id));
      expect(st.grouping, Grouping.project);
      await pump();
      await pump();
      expect(st.currentProject, q.id);
      expect(q.members.map((m) => m.key), contains(st.currentKey));
    });

    test('leaveProject goes back to no current project and records where', () async {
      final st = make();
      await open(['com.a']);
      final p = project(st, 'P', ['com.a']);
      st.switchProject(p.id);
      var n = 0;
      st.addListener(() => n++);
      st.leaveProject();
      expect((st.currentProject, st.previousProject, st.currentKey), (null, p.id, '111/com.a'));
      expect(n, greaterThan(0));
      final saved = ProjectPositions.load(DataDir(tmp.path).localDir).byProject[p.id]!;
      expect(saved.last, '111/com.a');
      expect(saved.leftAt!.isAtSameMomentAs(now), isTrue);
    });

    test('自由区 narrows to the sessions in no project; one in a project takes it back to 全部', () async {
      final st = make();
      await open(['com.a', 'com.b', 'com.c', 'com.d']);
      final p = project(st, 'P', ['com.a', 'com.c']);
      st.switchProject(p.id);
      st.switchFreeZone();
      expect((st.freeZone, st.currentProject, st.previousProject), (true, null, p.id));
      expect(st.freeZoneKeys, ['111/com.b', '111/com.d']);
      expect(st.currentKey, '111/com.b');
      st.step(1);
      expect(st.currentKey, '111/com.d');
      st.step(1);
      expect(st.currentKey, '111/com.b');
      expect(st.steppableCount, 2);
      // Picking a session in a project leaves 自由区 for 全部.
      st.select('111/com.a');
      expect((st.freeZone, st.currentProject), (false, null));
      st.switchFreeZone();
      st.switchProject(p.id);
      expect((st.freeZone, st.currentProject), (false, p.id));
      st.switchFreeZone();
      st.leaveProject();
      expect((st.freeZone, st.currentProject), (false, null));
    });

    test('stepping stays inside the current project', () async {
      final st = make();
      await open(['com.a', 'com.c', 'com.z']);
      final p = project(st, 'P', ['com.a', 'com.b', 'com.c']);
      st.switchProject(p.id);
      final seen = [st.currentKey];
      for (var i = 0; i < 4; i++) {
        st.step(1);
        seen.add(st.currentKey);
      }
      expect(seen, ['111/com.a', '111/com.c', '111/com.a', '111/com.c', '111/com.a']);
      st.step(-1);
      expect(st.currentKey, '111/com.c');
      expect(st.currentProject, p.id);
    });

    test('a project with nothing open can still be switched to', () {
      final st = make();
      final p = project(st, 'P', ['com.a']);
      st.switchProject(p.id);
      expect(st.currentKey, isNull);
      expect(st.currentProject, p.id);
      expect(st.grouping, Grouping.project);
    });

    test('the current session ending keeps the current project', () async {
      final st = make();
      await open(['com.a']);
      final p = project(st, 'P', ['com.a']);
      st.switchProject(p.id);
      t.emit({'event': 'closed', 'sid': 1});
      await pump();
      expect(st.currentKey, isNull);
      expect(st.currentProject, p.id);
    });

    test('the current session ending steps to the next one in the project, not outside it (S1)', () async {
      final st = make();
      await open(['com.a', 'com.b', 'com.z']);
      final p = project(st, 'P', ['com.b', 'com.a']); // a is last in P: next in the list would be z
      st.switchProject(p.id);
      st.select('111/com.a');
      t.emit({'event': 'closed', 'sid': 1});
      await pump();
      expect((st.currentKey, st.currentProject), ('111/com.b', p.id));
      t.emit({'event': 'closed', 'sid': 2});
      await pump();
      expect((st.currentKey, st.currentProject), (null, p.id));
      expect(st.entryFor('111/com.z'), isNotNull);
    });

    test('the current session ending steps to the next one in the project, not outside it (embedded)', () {
      fakeAsync((a) {
        final (port, st) = embedded(a);
        final p = project(st, 'P', ['aa', 'a']); // a is last in P: next in the list would be aaa
        st.switchProject(p.id);
        st.select('111/a');
        port.emit(const ClosedEvent(1, 'quit'));
        a.flushMicrotasks();
        expect((st.currentKey, st.currentProject), ('111/aa', p.id));
        port.emit(const ClosedEvent(2, 'quit'));
        a.flushMicrotasks();
        expect((st.currentKey, st.currentProject), (null, p.id));
        expect(st.entryFor('111/aaa'), isNotNull);
        st.dispose();
      });
    });

    test('positions of projects that no longer exist are dropped at start', () {
      final p = s.createProject('P')!;
      final local = DataDir(tmp.path).localDir;
      ProjectPositions({
        p.id: ProjectPosition(last: '111/com.a'),
        'gone': ProjectPosition(last: '111/com.b', leftAt: DateTime.utc(2026, 11, 14)),
      }).save(local);
      final st = make();
      expect(st.positions.byProject.keys, [p.id]);
      expect(st.currentProject, isNull);
    });

    test('deleting the current project clears it', () {
      final st = make();
      final p = project(st, 'P', []);
      final q = project(st, 'Q', []);
      st.switchProject(p.id);
      st.switchProject(q.id);
      st.deleteProject(q.id);
      expect((st.currentProject, st.previousProject), (null, p.id));
      st.deleteProject(p.id);
      expect((st.currentProject, st.previousProject), (null, null));
      expect(st.positions.byProject, isEmpty);
      st.backToPreviousProject();
      expect(st.currentProject, isNull);
    });

    group('relocate', () {
      late Directory other;
      late DataDir d;
      setUp(() {
        other = Directory.systemTemp.createTempSync('main_state_spheres_reloc');
        d = DataDir(other.path);
      });
      tearDown(() => other.deleteSync(recursive: true));

      test('reads the new root\'s positions and does not overwrite them', () {
        final st = make();
        final p = project(st, 'P', []);
        final q = project(st, 'Q', []);
        final r = project(st, 'R', []);
        st.switchProject(p.id);
        st.switchProject(q.id); // P's position is in memory and in the old root
        Directory(d.sharedDir).createSync(recursive: true);
        saveWorkspace(d.sharedDir, Workspace()..projects.addAll([Project(q.id, 'Q'), Project(r.id, 'R')]));
        final there = DateTime.utc(2026, 11, 14, 8);
        ProjectPositions({
          r.id: ProjectPosition(last: '111/com.r', leftAt: there),
          'gone': ProjectPosition(last: '111/com.g'),
        }).save(d.localDir);
        st.relocate(d);
        expect(st.positions.byProject.keys, [r.id]);
        expect(st.positions.byProject[r.id]!.last, '111/com.r');
        now = now.add(const Duration(minutes: 2));
        st.switchProject(r.id); // leaves Q: a save into the new root
        final saved = ProjectPositions.load(d.localDir).byProject;
        expect(saved.keys.toSet(), {q.id, r.id});
        expect(st.cue, isNotEmpty); // counted from the new root's leave
        expect(saved[r.id]!.last, '111/com.r');
        expect(saved.containsKey(p.id), isFalse);
      });

      test('a current or previous project the new root lacks is cleared, without an error', () {
        fakeAsync((a) {
          final st = make();
          final p = project(st, 'P', []);
          final q = project(st, 'Q', []);
          st.switchProject(p.id);
          st.switchProject(q.id);
          now = now.add(const Duration(minutes: 5));
          st.switchProject(p.id);
          expect(st.cue, '5 分钟前离开');
          Directory(d.sharedDir).createSync(recursive: true);
          saveWorkspace(d.sharedDir, Workspace());
          st.relocate(d);
          expect((st.currentProject, st.previousProject, st.cue, st.hint), (null, null, '', ''));
          st.backToPreviousProject();
          expect(st.currentProject, isNull);
          a.elapse(MainState.cueFor);
          expect(st.cue, '');
        });
      });

      test('a current and a previous project that exist in both roots stay', () {
        final st = make();
        final p = project(st, 'P', []);
        final q = project(st, 'Q', []);
        st.switchProject(p.id);
        st.switchProject(q.id);
        Directory(d.sharedDir).createSync(recursive: true);
        saveWorkspace(d.sharedDir, Workspace()..projects.addAll([Project(p.id, 'P'), Project(q.id, 'Q')]));
        st.relocate(d);
        expect((st.currentProject, st.previousProject), (q.id, p.id));
        st.backToPreviousProject();
        expect((st.currentProject, st.previousProject), (p.id, q.id));
      });
    });

    test('project-first preference starts grouped by project', () {
      expect(make(prefs: UiPrefs(first: FirstLayer.project)).grouping, Grouping.project);
      expect(make(prefs: UiPrefs(first: FirstLayer.device)).grouping, Grouping.device);
    });

    test('with no projects nothing changes', () {
      final st = make();
      expect((st.currentProject, st.previousProject, st.cue, st.grouping), (null, null, '', Grouping.device));
      expect(File('${DataDir(tmp.path).localDir}/$positionsFile').existsSync(), isFalse);
    });

    group('save as project, pin, undo delete', () {
      test('save what is open as a project and switch to it', () async {
        final st = make();
        await open(['a', 'b']);
        expect(st.canSaveOpenAsProject, isTrue);
        st.select('111/b');
        var sawEmpty = false;
        st.addListener(() => sawEmpty |= st.projects.any((p) => p.members.isEmpty));
        final p = st.saveOpenAsProject('写周报')!;
        expect(sawEmpty, isFalse);
        expect(st.currentKey, '111/b');
        expect(p.members.map((m) => m.key), ['111/a', '111/b']);
        expect(p.members.every((m) => m.task.isEmpty), isTrue);
        expect(st.currentProject, p.id);
        expect(File('${tmp.path}/shared/workspace.json').readAsStringSync(), contains('写周报'));
      });

      test('nothing open: cannot save, returns null, creates nothing', () {
        final st = make();
        expect(st.canSaveOpenAsProject, isFalse);
        expect(st.saveOpenAsProject('x'), isNull);
        expect(st.projects, isEmpty);
        expect(st.currentProject, isNull);
      });

      test('an empty name creates nothing', () async {
        final st = make();
        await open(['a']);
        expect(st.saveOpenAsProject('  '), isNull);
        expect(st.projects, isEmpty);
        expect(st.currentProject, isNull);
      });

      test('togglePinned persists', () {
        final st = make();
        final p = st.createProject('P')!;
        st.togglePinned(p.id);
        expect(make().projects.single.pinned, isTrue);
        st.togglePinned(p.id);
        expect(make().projects.single.pinned, isFalse);
      });

      test('a deleted project can be undone for five seconds and goes back where it was', () {
        fakeAsync((a) {
          final st = make();
          st.createProject('A');
          final b = st.createProject('B')!;
          st.createProject('C');
          st.addMember(b.id, const AppRef('111', 'x', 'X'));
          st.setTask(b.id, '111/x', '整理');
          st.togglePinned(b.id);
          st.deleteProject(b.id);
          expect(st.undoableDelete, 'B');
          expect(st.projects.map((p) => p.name), ['A', 'C']);
          st.undoDelete();
          expect(st.projects.map((p) => p.name), ['A', 'B', 'C']);
          final r = st.projects[1];
          expect((r.members.single.key, r.members.single.task, r.pinned), ('111/x', '整理', true));
          expect(st.undoableDelete, isNull);
          expect(File('${tmp.path}/shared/workspace.json').readAsStringSync(), contains('"B"'));
        });
      });

      test('undo restores the position, saved, but not current/previous', () {
        fakeAsync((a) {
          final st = make();
          final p = st.createProject('P')!;
          final q = st.createProject('Q')!;
          st.switchProject(p.id);
          st.switchProject(q.id); // P is left: it has a position
          final local = DataDir(tmp.path).localDir;
          st.deleteProject(p.id);
          expect(st.positions.byProject.containsKey(p.id), isFalse);
          expect(ProjectPositions.load(local).byProject.containsKey(p.id), isFalse);
          st.undoDelete();
          expect(st.projects.map((x) => x.name), ['P', 'Q']);
          expect((st.currentProject, st.previousProject), (q.id, null));
          expect(st.positions.byProject[p.id]!.leftAt!.isAtSameMomentAs(now), isTrue);
          expect(ProjectPositions.load(local).byProject[p.id]!.leftAt!.isAtSameMomentAs(now), isTrue);
        });
      });

      test('after five seconds it is gone for good', () {
        fakeAsync((a) {
          final st = make();
          final p = st.createProject('A')!;
          st.deleteProject(p.id);
          a.elapse(MainState.undoFor - const Duration(milliseconds: 1));
          expect(st.undoableDelete, 'A');
          a.elapse(const Duration(milliseconds: 1));
          expect(st.undoableDelete, isNull);
          st.undoDelete();
          expect(st.projects, isEmpty);
        });
      });

      test('deleting a second project forfeits the first undo', () {
        fakeAsync((a) {
          final st = make();
          final pa = st.createProject('A')!;
          final pb = st.createProject('B')!;
          st.deleteProject(pa.id);
          a.elapse(const Duration(seconds: 3));
          st.deleteProject(pb.id);
          expect(st.undoableDelete, 'B');
          // The first timer would fire at 5s; the second one must keep its own five seconds.
          a.elapse(const Duration(seconds: 3));
          expect(st.undoableDelete, 'B');
          st.undoDelete();
          expect(st.projects.map((p) => p.name), ['B']);
        });
      });

      test('undo saves', () {
        fakeAsync((a) {
          final st = make();
          final p = st.createProject('A')!;
          st.deleteProject(p.id);
          expect(make().projects, isEmpty);
          st.undoDelete();
          expect(make().projects.single.name, 'A');
        });
      });

      test('undo puts it last when the list is now shorter', () {
        fakeAsync((a) {
          final st = make();
          st.createProject('A');
          final b = st.createProject('B')!;
          final c = st.createProject('C')!;
          st.deleteProject(c.id);
          st.deleteProject(b.id);
          st.undoDelete();
          expect(st.projects.map((p) => p.name), ['A', 'B']);
        });
      });

      test('deleting the current project clears its cue', () {
        fakeAsync((a) {
          final st = make();
          final p = st.createProject('P')!;
          final q = st.createProject('Q')!;
          st.switchProject(p.id);
          st.switchProject(q.id);
          now = now.add(const Duration(minutes: 5));
          st.switchProject(p.id);
          expect(st.cue, isNotEmpty);
          st.deleteProject(p.id);
          expect(st.cue, '');
        });
      });

      test('dispose cancels the undo timer', () {
        fakeAsync((a) {
          final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), clock: () => now);
          final p = st.createProject('P')!;
          st.deleteProject(p.id);
          st.dispose();
          expect(a.pendingTimers, isEmpty);
        });
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

  group('the 终端 entry', () {
    Map<String, dynamic> ptyRow(String name, int activity) =>
        {'id': 'term:pty:$name', 'name': name, 'command': 'zsh', 'activity': activity};

    Future<void> termsOf(List<Map<String, dynamic>> terms,
        {List<String> launchers = const ['Terminal'], List<Map<String, dynamic>>? shells}) async {
      t.emit({
        'event': 'terms',
        'id': '111',
        'path': 'lan',
        'terms': terms,
        'hosts': [
          {'host': null, 'launchers': launchers, 'shells': ?shells},
        ],
      });
      await pump();
    }

    test('opening terms: in text mode with none opens the default shell in the chosen app', () async {
      t.onSend = (m) {
        if (m['cmd'] == 'open_term') t.emit({'event': 'term_created', 'req': m['req'], 'id': '111', 'term': 'term:pty:zsh'});
        if (m['cmd'] == 'terms') t.emit({'event': 'terms', 'req': m['req'], 'id': '111', 'terms': [], 'hosts': []});
      };
      await termsOf([], launchers: ['Terminal', 'iTerm'], shells: [
        {'name': 'zsh', 'path': '/bin/zsh', 'default': true}
      ]);
      s.setTermApp('111', 'iTerm');
      await s.openOrSwitch('111', 'terms:', '终端');
      await pump();
      expect(t.sent.firstWhere((m) => m['cmd'] == 'open_term'),
          {'cmd': 'open_term', 'id': '111', 'shell': '/bin/zsh', 'app': 'iTerm', 'req': anything});
    });

    test('opening terms: in text mode opens the latest text terminal', () async {
      await termsOf([ptyRow('a', 5), ptyRow('b', 7)]);
      s.openOrSwitch('111', 'terms:', '终端');
      expect(t.sent.lastWhere((m) => m['cmd'] == 'open')['app'], 'term:pty:b');
      expect(s.currentKey, '111/term:pty:b');
    });

    test('opening terms: in pixels mode opens the terminal app', () async {
      await termsOf([ptyRow('a', 5)]);
      s.setTermOpen('111', 'pixels');
      s.openOrSwitch('111', 'terms:', '终端');
      expect(t.sent.lastWhere((m) => m['cmd'] == 'open')['app'], 'com.apple.Terminal');
    });

    test('setTermApp is saved per device', () {
      Directory('${tmp.path}/local').createSync(recursive: true);
      File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
      s.setTermApp('111', 'iTerm');
      expect(UiPrefs.load(s.data.prefsDir()!).termApp, {'111': 'iTerm'});
    });

    test('setTermOpen is saved per device', () {
      Directory('${tmp.path}/local').createSync(recursive: true);
      File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
      s.setTermOpen('111', 'pixels');
      final p = UiPrefs.load(s.data.prefsDir()!);
      expect((p.termOpenFor('111'), p.termOpenFor('222')), ('pixels', 'text'));
    });

    test('open all opens a terms: member the way tapping it does', () async {
      await termsOf([ptyRow('a', 5), ptyRow('b', 7)]);
      final p = s.createProject('写周报')!;
      s.addMember(p.id, const AppRef('111', 'terms:', '终端'));
      s.openAll(p.id);
      await pump();
      final apps = t.sent.where((m) => m['cmd'] == 'open').map((m) => m['app']);
      expect(apps, ['term:pty:b']);
      expect(s.entryFor('111/term:pty:b')!.lamp, Lamp.connecting);
      expect(s.currentKey, '111/term:pty:b');
      expect(s.hint, '写周报：打开 1 个');
    });

    test('terms: can be a favorite', () {
      s.toggleFavorite('111', 'terms:', '终端');
      expect(s.isFavorite('111', 'terms:'), isTrue);
      expect(s.favorites.single.name, '终端');
    });

    test('openText opens the new session right away', () async {
      await termsOf([]);
      t.onSend = (m) {
        switch (m['cmd']) {
          case 'open_term':
            t.emit({'event': 'term_created', 'req': m['req'], 'id': '111', 'term': 'term:pty:c'});
          case 'terms':
            t.emit({
              'event': 'terms',
              'req': m['req'],
              'id': '111',
              'terms': [ptyRow('c', 1)],
              'hosts': [
                {'host': null, 'launchers': ['Terminal']},
              ],
            });
          case 'open':
            t.emit({...opened(1, '111', 'term:pty:c'), 'req': m['req']});
        }
      };
      await s.openText('111', shell: '/bin/zsh');
      await pump();
      final ot = t.sent.firstWhere((m) => m['cmd'] == 'open_term');
      expect(ot, {'cmd': 'open_term', 'id': '111', 'shell': '/bin/zsh', 'app': 'Terminal', 'req': anything});
      expect(t.sent.map((m) => m['cmd']), containsAllInOrder(['open_term', 'terms', 'open']));
      expect(t.sent.lastWhere((m) => m['cmd'] == 'open')['app'], 'term:pty:c');
      expect(s.currentKey, '111/term:pty:c');
      expect(s.current!.appName, 'c');
    });

    test('openText gives a refusal to the caller and opens nothing', () async {
      await termsOf([]);
      t.onSend = (m) {
        if (m['cmd'] == 'open_term') t.emit({'event': 'error', 'req': m['req'], 'error': 'no such directory: /x'});
      };
      await expectLater(s.openText('111', shell: '/x'),
          throwsA(isA<HubException>().having((e) => e.message, 'message', 'no such directory: /x')));
      expect(opens(), 0);
    });
  });

  group('terminal needs', () {
    TermRow row(String id, TermPs? ps, {bool dead = false}) =>
        TermRow(id, id.split(':').last, 'claude', null, 1, 0, 0, dead, false, ps: ps);
    void put(List<TermRow> rows) => s.hub!.termLists['111'] = TermList('111', terms: rows);

    test('a blocked terminal is in needs until it is not', () {
      put([
        row('term:pty:a', const TermPs('blocked', kind: 'permission', msg: 'approve Bash: ls', seq: 3)),
        row('term:pty:b', const TermPs('working', seq: 1)),
      ]);
      final n = s.needs.single;
      expect((n.kind, n.target, n.device, n.title), (NeedKind.terminal, 'term:pty:a', '111', 'a'));
      expect(n.text, endsWith('等确认 · approve Bash: ls'));
      put([row('term:pty:a', const TermPs('working', seq: 4))]);
      expect(s.needs, isEmpty);
    });

    test('a device that dropped has no terminal needs', () async {
      put([row('term:pty:a', const TermPs('blocked', seq: 3))]);
      expect(s.needs, hasLength(1));
      t.emit({'event': 'presence', 'id': '111', 'online': false});
      await pump();
      expect(s.needs.where((n) => n.kind == NeedKind.terminal), isEmpty);
      t.emit({'event': 'presence', 'id': '111', 'online': true});
      await pump();
      expect(s.needs.where((n) => n.kind == NeedKind.terminal), hasLength(1));
    });

    test('an opened terminal whose program is blocked has the waiting lamp', () async {
      Future<void> list(String state, {bool dead = false}) async {
        t.emit({
          'event': 'terms',
          'id': '111',
          'terms': [
            {'id': 'term:pty:a', 'name': 'a', 'command': 'claude', 'activity': 1, 'dead': dead, 'ps': {'state': state, 'seq': 3}},
          ],
          'hosts': [],
        });
        await pump();
      }

      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit({...opened(1, '111', 'term:pty:a'), 'req': m['req']});
      };
      await s.openOrSwitch('111', 'term:pty:a', 'a');
      await pump();
      expect(s.current!.lamp, Lamp.active);
      await list('blocked');
      expect(s.current!.lamp, Lamp.waiting);
      await list('blocked', dead: true);
      expect(s.current!.lamp, Lamp.active);
      await list('working');
      expect(s.current!.lamp, Lamp.active);
    });

    test('an opened terminal carries its live program status; not when dead or its device is offline', () async {
      Future<void> list(String state, {bool dead = false, String? msg}) async {
        t.emit({
          'event': 'terms',
          'id': '111',
          'terms': [
            {'id': 'term:pty:a', 'name': 'a', 'command': 'claude', 'activity': 1, 'dead': dead, 'ps': {'state': state, 'seq': 3, 'msg': ?msg}},
          ],
          'hosts': [],
        });
        await pump();
      }

      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit({...opened(1, '111', 'term:pty:a'), 'req': m['req']});
      };
      await s.openOrSwitch('111', 'term:pty:a', 'a');
      await pump();
      expect(s.current!.ps, isNull);
      await list('working');
      expect(s.current!.ps?.state, 'working');
      await list('done', msg: 'ok');
      expect((s.current!.ps?.state, s.current!.ps?.msg), ('done', 'ok'));
      await list('blocked', dead: true);
      expect(s.current!.ps, isNull);
      await list('blocked');
      expect(s.current!.lamp, Lamp.waiting);
      t.emit({'event': 'presence', 'id': '111', 'online': false});
      await pump();
      expect(s.entries.where((e) => e.key == '111/term:pty:a').map((e) => (e.ps, e.lamp == Lamp.waiting)), everyElement((null, false)));
    });

    test('a dead session that was blocked is not in needs', () {
      put([row('term:pty:a', const TermPs('blocked'), dead: true)]);
      expect(s.needs, isEmpty);
    });

    test('a new ask comes first; the same ask keeps its place', () {
      put([row('term:pty:a', const TermPs('blocked', seq: 3))]);
      expect(s.needs.map((n) => n.target), ['term:pty:a']);
      put([
        row('term:pty:a', const TermPs('blocked', seq: 3)),
        row('term:pty:b', const TermPs('blocked', seq: 1)),
      ]);
      expect(s.needs.map((n) => n.target), ['term:pty:b', 'term:pty:a']);
      expect(s.needs.map((n) => n.target), ['term:pty:b', 'term:pty:a']);
      put([
        row('term:pty:a', const TermPs('blocked', seq: 5)),
        row('term:pty:b', const TermPs('blocked', seq: 1)),
      ]);
      expect(s.needs.map((n) => n.target), ['term:pty:a', 'term:pty:b']);
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

class _DelayedTakeEditor extends FakeEditor {
  final gate = Completer<void>();
  @override
  Future<String> take() async {
    await gate.future;
    return super.take();
  }
}
