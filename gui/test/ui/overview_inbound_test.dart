// The overview's 本机 column lists the sessions other devices hold on this machine (正在被接入).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import 'helpers.dart';

/// A monitor that never connects: the test sets [status] and records kicks.
class _Mon extends ServiceMonitor {
  _Mon() : super(readToken: () async => null);
  final kicked = <Object>[];
  Object? failWith;

  void set(List<ServiceSession> sessions) {
    status = ServiceStatus(sessions: sessions);
    notifyListeners();
  }

  @override
  Future<void> kick(Object sid) async {
    kicked.add(sid);
    if (failWith != null) throw failWith!;
  }
}

void main() {
  late FakeTransport t;
  late MainState s;
  late Directory tmp;
  final epoch = DateTime(2026, 11, 13, 12);
  final secs = epoch.millisecondsSinceEpoch ~/ 1000;

  ServiceSession inbound(int sid, String peer, String app, {String? name, int ago = 12, bool side = false}) =>
      ServiceSession(sid, peer, app, 'relay', secs - ago, name: name, side: side);

  setUp(() => tmp = Directory.systemTemp.createTempSync('overview_inbound_test'));
  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester, {ServiceMonitor? monitor}) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    t = FakeTransport();
    t.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        t.emit({'event': 'hosts', 'req': m['req'], 'hosts': [{'id': 'm1', 'name': 'mini'}]});
      } else if (m['cmd'] == 'apps') {
        t.emit({'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan', 'apps': []});
      }
    };
    s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), clock: () => epoch);
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    s.toggleOverview();
    await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s, monitor: monitor))));
    await tester.pump();
  }

  Finder inside(String key, Finder f) => find.descendant(of: find.byKey(Key(key)), matching: f);

  testWidgets('inbound sessions show under 正在被接入 in the 本机 column', (tester) async {
    final m = _Mon()..set([inbound(1, 'm1', 'com.apple.Safari', ago: 200), inbound(2, '1.2.3.4:5', 'term:pty:zsh', name: 'iPad')]);
    await show(tester, monitor: m);
    expect(inside('column-local', find.text('正在被接入 · 2')), findsOneWidget);
    expect(inside('inbound-1', find.text('com.apple.Safari')), findsOneWidget);
    expect(inside('inbound-1', find.text('mini · 3 分钟')), findsOneWidget);
    expect(inside('inbound-2', find.text('CLI · zsh')), findsOneWidget);
    expect(inside('inbound-2', find.text('iPad · 12 秒')), findsOneWidget);
    // The first one comes first, as the service lists them.
    expect(tester.getTopLeft(find.byKey(const Key('inbound-1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('inbound-2'))).dy));
    // Not on a remote column.
    expect(inside('column-m1', find.text('正在被接入 · 2')), findsNothing);
  });

  testWidgets('a file transfer says 传文件', (tester) async {
    final m = _Mon()..set([inbound(3, 'm1', 'com.apple.Safari', side: true)]);
    await show(tester, monitor: m);
    expect(inside('inbound-3', find.text('mini · 12 秒 · 传文件')), findsOneWidget);
  });

  testWidgets('tapping 断开 kicks that session', (tester) async {
    final m = _Mon()..set([inbound(1, 'm1', 'a'), inbound(2, 'm1', 'b')]);
    await show(tester, monitor: m);
    await tester.tap(find.byKey(const Key('inbound-kick-2')));
    await tester.pump();
    expect(m.kicked, [2]);
  });

  testWidgets('a failed kick shows 断开失败', (tester) async {
    final m = _Mon()
      ..set([inbound(1, 'm1', 'a')])
      ..failWith = ServiceException('no such session');
    await show(tester, monitor: m);
    await tester.tap(find.byKey(const Key('inbound-kick-1')));
    await tester.pump();
    expect(find.text('断开失败：no such session'), findsOneWidget);
    expect(find.byKey(const Key('inbound-1')), findsOneWidget);
  });

  testWidgets('no monitor or no status: no inbound group', (tester) async {
    await show(tester);
    expect(find.byKey(const Key('inbound-title')), findsNothing);
    s.dispose();
    final m = _Mon(); // never connected: status is null
    await show(tester, monitor: m);
    expect(find.byKey(const Key('inbound-title')), findsNothing);
    m.set(const []);
    await tester.pump();
    expect(find.byKey(const Key('inbound-title')), findsNothing);
  });

  testWidgets('the group follows the monitor as sessions come and go', (tester) async {
    final m = _Mon()..set(const []);
    await show(tester, monitor: m);
    expect(find.byKey(const Key('inbound-title')), findsNothing);
    m.set([inbound(1, 'm1', 'a')]);
    await tester.pump();
    expect(find.text('正在被接入 · 1'), findsOneWidget);
    m.set(const []);
    await tester.pump();
    expect(find.byKey(const Key('inbound-1')), findsNothing);
  });

  testWidgets('display name falls back to the peer id', (tester) async {
    final m = _Mon()..set([inbound(1, '1.2.3.4:5', 'a')]);
    await show(tester, monitor: m);
    expect(inside('inbound-1', find.text('1.2.3.4:5 · 12 秒')), findsOneWidget);
  });

  testWidgets('long names ellipsize and keep 断开 on screen', (tester) async {
    final long = 'x' * 200;
    final m = _Mon()..set([inbound(1, '1.2.3.4:5', long, name: long)]);
    await show(tester, monitor: m);
    expect(tester.takeException(), isNull);
    final card = tester.getRect(find.byKey(const Key('inbound-1')));
    final kick = tester.getRect(find.byKey(const Key('inbound-kick-1')));
    expect(card.contains(kick.center), isTrue);
    final title = tester.widget<Text>(inside('inbound-1', find.text(long)));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
  });

  testWidgets('tapping an inbound card selects nothing and is not a button', (tester) async {
    final m = _Mon()..set([inbound(1, 'm1', 'a')]);
    await show(tester, monitor: m);
    final before = s.currentKey;
    await tester.tapAt(tester.getTopLeft(find.byKey(const Key('inbound-1'))) + const Offset(40, 20));
    await tester.pump();
    expect(s.currentKey, before);
    expect(m.kicked, isEmpty);
    expect(inside('inbound-1', find.byType(InkWell)).evaluate().length,
        inside('inbound-kick-1', find.byType(InkWell)).evaluate().length,
        reason: 'the only ink on the card is the 断开 button');
    final sem = tester.getSemantics(inside('inbound-1', find.byType(Semantics)).first);
    expect(sem.label, '正在被接入，a，mini', reason: 'app and who, no age: the label must not change every second');
    expect(sem.getSemanticsData().flagsCollection.isButton, isFalse);
  });

  testWidgets('inbound sessions do not change the counts', (tester) async {
    final m = _Mon()..set([inbound(1, 'm1', 'a'), inbound(2, 'm1', 'b')]);
    await show(tester, monitor: m);
    Text n(String key) => tester.widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)).first);
    expect(n('count-active').data, '0');
  });
}
