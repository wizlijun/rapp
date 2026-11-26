// rapp-state P3: the app reports the states it infers for GUI clients, and shows other apps' reports as 推断.
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/ui/app_profile_store.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

void main() {
  late Directory tmp;
  final rulesJson = File('assets/state_rules.json').readAsStringSync();
  const codex = 'com.openai.codex';
  const key = '111/$codex';

  setUp(() => tmp = Directory.systemTemp.createTempSync('state_p3_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String report(String state, {bool sure = false, String? kind}) => jsonEncode({
        'state': state, 'sure': sure, 'kind': kind, 'health': 'ok', 'counts': <String, int>{}, 'by': <String>[],
        'pack': 'chatgpt-desktop', 'rev': 1,
      });

  /// A live GUI session of [codex] on host 111 (`mini`, fingerprint [fp]), rules sent, in an app whose own
  /// fingerprint is `appA`. [sync] null: no state service wired in.
  void env(void Function(FakeAsync a, FakeTransport t, FakeSessionPort port, MainState st, Object sid) body,
      {String? fp = 'devA', FakeStateSync? sync, bool noSync = false, AppProfileStore? profiles}) {
    fakeAsync((a) {
      final t = FakeTransport();
      final hub = HubClient(t);
      t.emit({
        'event': 'hosts',
        'me': 'appA',
        'name': 'Mac',
        'hosts': [
          {'id': '111', 'name': 'mini', 'fp': ?fp},
        ],
      });
      a.flushMicrotasks();
      final port = FakeSessionPort();
      final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, builtinStateRules: rulesJson, profiles: profiles,
          stateSync: noSync ? null : (sync ?? FakeStateSync(tmp.path)));
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
      st.openOrSwitch('111', codex, 'ChatGPT');
      a.flushMicrotasks();
      final sid = st.currentRecord!.sid!;
      port.emit(ReadyEvent(sid, 'ChatGPT'));
      body(a, t, port, st, sid);
      st.dispose();
    });
  }

  group('rapp-state P3 proxy reports', () {
    test('the hub hosts event tells the out who this app is', () {
      final sync = FakeStateSync(tmp.path);
      env((a, t, port, st, sid) {
        expect(sync.out.mes.last, ('appA', 'Mac'));
      }, sync: sync);
    });

    test('a sure block is reported, then gone when the session ends', () {
      final sync = FakeStateSync(tmp.path);
      env((a, t, port, st, sid) {
        port.emit(AppStateEvent(sid, report('blocked', sure: true, kind: 'permission')));
        expect(sync.out.reports.last,
            ('devA', '111', codex, (state: 'blocked', kind: 'permission', app: 'chatgpt-desktop', name: 'ChatGPT')));
        port.emit(AppStateEvent(sid, report('working')));
        expect(sync.out.reports.last.$4, (state: 'working', kind: null, app: 'chatgpt-desktop', name: 'ChatGPT'));
        expect(st.endSession(key), isTrue);
        port.emit(ClosedEvent(sid, 'closed'));
        a.flushMicrotasks();
        expect(st.recordFor(key), isNull);
        expect(sync.out.reports.last, ('devA', '111', codex, null));
      }, sync: sync);
    });

    test('an unsure block and a link drop are not reported', () {
      final sync = FakeStateSync(tmp.path);
      env((a, t, port, st, sid) {
        port.emit(AppStateEvent(sid, report('blocked', kind: 'permission')));
        expect(sync.out.reports, isEmpty);
        port.emit(AppStateEvent(sid, report('working')));
        expect(sync.out.reports, hasLength(1));
        // a sure state followed by an unsure block: what was reported no longer stands
        port.emit(AppStateEvent(sid, report('blocked', kind: 'permission')));
        expect(sync.out.reports.last, ('devA', '111', codex, null));
        port.emit(AppStateEvent(sid, report('working')));
        final n = sync.out.reports.length;
        port.emit(DisconnectedEvent(sid, 'connection closed'));
        a.flushMicrotasks();
        expect(sync.out.reports, hasLength(n));
      }, sync: sync);
    });

    test('rules that change clear the inference: gone', () {
      final sync = FakeStateSync(tmp.path);
      final profiles = AppProfileStore('${tmp.path}/shared', mine: [], builtin: []);
      env((a, t, port, st, sid) {
        port.emit(AppStateEvent(sid, report('working')));
        expect(sync.out.reports.last.$4?.state, 'working');
        profiles.setStateRules(codex, 'App', 'off');
        expect(sync.out.reports.last, ('devA', '111', codex, null));
      }, sync: sync, profiles: profiles);
    });

    test('no fp, no report', () {
      final sync = FakeStateSync(tmp.path);
      env((a, t, port, st, sid) {
        port.emit(AppStateEvent(sid, report('blocked', sure: true, kind: 'permission')));
        st.endSession(key);
        port.emit(ClosedEvent(sid, 'closed'));
        a.flushMicrotasks();
        expect(sync.out.reports, isEmpty);
      }, sync: sync, fp: null);
    });

    test('no state service: the GUI session goes on as before', () {
      env((a, t, port, st, sid) {
        port.emit(AppStateEvent(sid, report('working')));
        port.emit(AppStateEvent(sid, report('blocked', sure: true, kind: 'permission')));
        final n = st.needs.single;
        expect(n.kind, NeedKind.app);
        expect(n.text, isNot(endsWith('（推断）')));
        expect(st.queueRows.where((r) => r.inferred), hasLength(1));
      }, noSync: true);
    });
  });

  group('rapp-state P3 service app rows', () {
    Map<String, Object?> need(String session) =>
        {'fp': 'devA', 'id': '111', 'session': session, 'src': 'app', 'state': 'blocked', 'kind': 'permission', 'since': 5};

    test('a service app need is marked inferred and opens on tap', () {
      final sync = FakeStateSync(tmp.path)..ids['devA'] = '111';
      env((a, t, port, st, sid) {
        // this app reads 111's terminals itself: that does not hide another app's report
        st.hub!.termLists['111'] = TermList('111', terms: []);
        sync.sessions['devA\ncom.x'] = {'session': 'com.x', 'src': 'app', 'name': 'Claude', 'state': 'blocked'};
        sync
          ..status = StateStatus.connected
          ..needs = [need('com.x')]
          ..push();
        final n = st.needs.where((x) => x.kind == NeedKind.app).single;
        expect(n.text, 'Claude @ mini：等确认（推断）');
        expect((n.target, n.device, n.title, n.at, n.greyWord), ('111/com.x', '111', 'Claude', 5, null));
        t.sent.clear();
        st.goToNeed(n);
        a.flushMicrotasks();
        final open = t.sent.where((m) => m['cmd'] == 'open').single;
        expect((open['id'], open['app']), ('111', 'com.x'));
        expect(st.entryFor('111/com.x')?.appName, 'Claude');
      }, sync: sync);
    });

    test('a service app need is skipped when this app has it live', () {
      final sync = FakeStateSync(tmp.path)..ids['devA'] = '111';
      env((a, t, port, st, sid) {
        port.emit(AppStateEvent(sid, report('blocked', sure: true, kind: 'permission')));
        sync.sessions['devA\n$codex'] = {'session': codex, 'src': 'app', 'name': 'ChatGPT', 'state': 'blocked'};
        sync
          ..status = StateStatus.connected
          ..needs = [need(codex)]
          ..push();
        final n = st.needs.where((x) => x.kind == NeedKind.app).single;
        expect(n.target, key);
        expect(n.text, isNot(endsWith('（推断）')));
      }, sync: sync);
    });

    test('service app rows queue as inferred and local inferred rows step aside', () {
      final sync = FakeStateSync(tmp.path)..ids['devA'] = '111';
      env((a, t, port, st, sid) {
        port.emit(AppStateEvent(sid, report('working')));
        port.emit(AppStateEvent(sid, report('done')));
        expect(st.hintHistory.where((r) => r.inferred), hasLength(1));
        sync
          ..status = StateStatus.connected
          ..rows = [
            {'t': 'state', 'eid': 'devA:e:1', 'fp': 'devA', 'id': '111', 'session': 'com.x', 'src': 'app', 'name': 'Claude',
              'state': 'blocked', 'kind': 'permission', 'at': 100},
            {'t': 'state', 'eid': 'devA:e:2', 'fp': 'devA', 'id': '111', 'session': 'com.y', 'src': 'app', 'state': 'working', 'at': 90},
          ]
          ..push();
        final rows = st.queueRows;
        expect(rows.where((r) => r.eid == null && r.inferred), isEmpty);
        final x = rows.singleWhere((r) => r.eid == 'devA:e:1');
        expect(x.inferred, isTrue);
        expect(x.text, startsWith('Claude @ mini：'));
        expect((x.device, x.app, x.title, x.goes), ('111', 'com.x', 'Claude', true));
        final y = rows.singleWhere((r) => r.eid == 'devA:e:2');
        expect((y.inferred, y.title), (true, 'com.y'));
        sync
          ..status = StateStatus.unreachable
          ..push();
        expect(st.queueRows.where((r) => r.eid == null && r.inferred), hasLength(1));
      }, sync: sync);
    });
  });
}
