import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('phone_flags_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, dynamic> opened(int sid, String app, {Object? req}) =>
      {'event': 'opened', 'sid': sid, 'id': '111', 'app': app, 'path': 'lan', 'port': 5000 + sid, 'token': 'tk', 'req': req};

  RemoteWindow rw(int id) => RemoteWindow(
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

  /// Two graphic sessions ('a' is sid 1, 'aa' is sid 2; 'aa' is current).
  void env(void Function(FakeAsync a, FakeSessionPort port, MainState st) body) {
    fakeAsync((a) {
      final t = FakeTransport();
      final hub = HubClient(t);
      final port = FakeSessionPort();
      t.emit({
        'event': 'hosts',
        'hosts': [
          {'id': '111', 'name': 'mini'},
        ],
      });
      final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
      t.onSend = (m) {
        if (m['cmd'] == 'open') t.emit(opened((m['app'] as String).length, m['app'] as String, req: m['req']));
      };
      a.flushMicrotasks();
      for (final app in ['a', 'aa']) {
        st.openOrSwitch('111', app, 'App');
        a.flushMicrotasks();
      }
      body(a, port, st);
      st.dispose();
    });
  }

  List<Map<String, Object?>> resizes(FakeSessionPort port) => [for (final c in port.calls) if (c.$1 == 'resize') c.$2];
  List<Map<String, Object?>> sets(FakeSessionPort port, int sid) =>
      [for (final c in port.calls) if (c.$1 == 'set_stream' && c.$2['sid'] == sid) c.$2];

  test('no resize while phone form', () {
    env((a, port, st) {
      st.stageSize(const Size(1194, 834));
      port.emit(const ReadyEvent(2, 'App'));
      port.emit(WindowsEvent(2, [rw(7)]));
      a.elapse(const Duration(seconds: 1));
      final before = resizes(port).length;
      expect(before, 1);
      st.setPhone(form: true);
      st.select('111/a');
      port.emit(const ReadyEvent(1, 'App'));
      port.emit(WindowsEvent(1, [rw(3)]));
      a.elapse(const Duration(seconds: 1));
      expect(resizes(port).length, before);
    });
  });

  test('pad after phone resizes at most once', () {
    env((a, port, st) {
      st.stageSize(const Size(1194, 834));
      port.emit(const ReadyEvent(2, 'App'));
      port.emit(WindowsEvent(2, [rw(7)]));
      a.elapse(const Duration(seconds: 1));
      st.setPhone(form: true);
      st.setPhone(form: false);
      final before = resizes(port).length;
      st.stageSize(const Size(1000, 700));
      a.elapse(const Duration(seconds: 1));
      expect(resizes(port).length, before + 1);
      st.stageSize(const Size(1000, 700));
      a.elapse(const Duration(seconds: 1));
      expect(resizes(port).length, before + 1);
    });
  });

  // A session entered on the phone took the old Pad stage size while the phone form held the send back; back on
  // the Pad, the same stage size must still be judged (and sent once), not taken as nothing new.
  test('unfold to the same pad size resizes a session entered on the phone', () {
    env((a, port, st) {
      st.stageSize(const Size(1194, 834));
      port.emit(const ReadyEvent(2, 'App'));
      port.emit(WindowsEvent(2, [rw(7)]));
      a.elapse(const Duration(seconds: 1));
      st.setPhone(form: true);
      st.select('111/a');
      port.emit(const ReadyEvent(1, 'App'));
      port.emit(WindowsEvent(1, [rw(3)]));
      a.elapse(const Duration(seconds: 1));
      final before = resizes(port).length;
      st.setPhone(form: false);
      st.stageSize(const Size(1194, 834));
      a.elapse(const Duration(seconds: 1));
      expect(resizes(port).length, before + 1);
      expect(resizes(port).last['sid'], 1);
      // Still once: the same size again is nothing new.
      st.stageSize(const Size(1194, 834));
      a.elapse(const Duration(seconds: 1));
      expect(resizes(port).length, before + 1);
    });
  });

  test('home pauses pictures', () {
    env((a, port, st) {
      port.emit(const TrafficEvent(2, 900, 3));
      st.setPhone(form: true);
      expect(sets(port, 2).last['fps'], 0);
      st.setPhone(form: true, inSession: true);
      expect(sets(port, 2).last['fps'], 15);
    });
  });

  test('phone home does not mark seen', () async {
    final t = FakeTransport();
    final hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    final sync = FakeStateSync(tmp.path)..ids['F'] = '111';
    final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), stateSync: sync);
    addTearDown(st.dispose);
    hub.termLists['111'] = TermList('111', terms: [TermRow('term:pty:t1', 'rapp', 'claude', null, 1, 0, 0, false, false)]);
    st.setPhone(form: true);
    t.onSend = (m) {
      if (m['cmd'] == 'open') t.emit({...opened(1, m['app'] as String, req: m['req'])});
    };
    await st.openOrSwitch('111', 'term:pty:t1', 'rapp');
    await Future<void>.delayed(Duration.zero);
    expect(st.currentKey, '111/term:pty:t1');
    expect(sync.seenCalls, isEmpty);
    st.setPhone(form: true, inSession: true);
    expect(sync.seenCalls, [('111', 'term:pty:t1')]);
  });

  test('entering phone form closes panel and overview', () {
    env((a, port, st) {
      st.showPanel(PanelTab.devices);
      st.overview = true;
      st.setPhone(form: true);
      expect(st.panel, isNull);
      expect(st.overview, isFalse);
      expect(st.logs, isFalse);
      expect(st.phoneForm, isTrue);
      expect(st.phoneInSession, isFalse);
    });
  });
}
