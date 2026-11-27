import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/phone/home_screen.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/widgets.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';

class _Sync extends FakeStateSync {
  _Sync(super.localDir);
  final handled = <String>[];
  @override
  Future<void> markHandled(String eid) async => handled.add(eid);
}

const _gb = 1000000000;

Map<String, dynamic> _load(String id) => {
      'event': 'load', 'id': id, 'at': 1764100000, 'headroom': 10, 'tightest': 'cpu', 'term': true,
      'items': {'cpu': {'pct': 95}},
      'disks': [
        {'mount': '/', 'total': 100 * _gb, 'avail': 6 * _gb, 'level': 'warn', 'paths': []},
      ],
      'warnings': [
        {'item': 'cpu', 'level': 'warn', 'text': 'CPU 持续 90% 以上'},
      ],
      'history': [],
    };

void main() {
  late Directory tmp;
  late FakeTransport t;
  late MainState s;
  late PhoneNav nav;
  late FakeSessionPort port;
  var sid = 0;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    sid = 0;
    tmp = Directory.systemTemp.createTempSync('home_screen_test');
  });
  tearDown(() {
    nav.dispose();
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> term(String id, String state, {String? kind, String msg = '', bool unread = false, int? progress}) => {
        'id': 'term:pty:$id',
        'name': id,
        'command': 'zsh',
        'activity': 1,
        'unread': unread,
        'fg': 'codex',
        'ps': {'state': state, 'kind': ?kind, 'msg': msg, 'since': 10, 'seq': 1, 'progress': ?progress},
      };

  Future<void> emit(WidgetTester tester, Map<String, dynamic> m) async {
    t.emit(m);
    await tester.runAsync(flush);
    await tester.pump();
  }

  Future<void> terms(WidgetTester tester, List<Map<String, Object?>> rows) =>
      emit(tester, {'event': 'terms', 'id': 'm1', 'path': 'lan', 'terms': rows, 'hosts': []});

  List<Map<String, Object?>> blocked(int n) => [for (var i = 0; i < n; i++) term('w$i', 'blocked', kind: 'permission', msg: 'ok$i?')];

  Future<void> boot(WidgetTester tester, {bool disableAnimations = false, bool noHosts = false, bool termPort = false, FakeStateSync? sync}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    t = FakeTransport();
    final hub = HubClient(t);
    if (!noHosts) {
      t.emit({
        'event': 'hosts',
        'hosts': [
          {'id': 'm1', 'name': 'mini'},
        ],
      });
    }
    await tester.runAsync(flush);
    port = FakeSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: termPort ? FakeTermSessionPort() : null, stateSync: sync);
    nav = PhoneNav(s);
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req'], if (m['embed'] == true) ...{'port': 5000 + sid, 'token': 'tk'}});
      } else if (m['req'] is int) {
        t.emit({'event': 'error', 'req': m['req'], 'error': 'test'});
      }
    };
    await tester.pumpWidget(MaterialApp(
      theme: themeDataFor(RappTheme.matrix),
      builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations), child: c!),
      home: Scaffold(body: HomeScreen(state: s, nav: nav)),
    ));
  }

  /// Was in [key]: the session is open (an entry), then left for home.
  Future<void> cameFromOpen(WidgetTester tester, String key) async {
    final slash = key.indexOf('/');
    await tester.runAsync(() async {
      s.openOrSwitch(key.substring(0, slash), key.substring(slash + 1), key.substring(slash + 1));
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    nav.cameFrom = key;
  }

  int taps(WidgetTester tester) {
    var n = 0;
    for (final w in tester.widgetList(find.byWidgetPredicate((w) => w is InkWell || w is PhoneButton))) {
      if (w is InkWell && w.onTap != null) n++;
      if (w is PhoneButton && w.onPressed != null) n++;
    }
    return n;
  }

  testWidgets('count line', (tester) async {
    await boot(tester);
    expect(find.text('没有等你的。'), findsOneWidget);
    await terms(tester, blocked(3));
    expect(find.text('3 件等你'), findsOneWidget);
    expect(find.text('没有等你的。'), findsNothing);
  });

  testWidgets('second line halves', (tester) async {
    await boot(tester);
    await terms(tester, [term('a', 'working'), term('b', 'working')]);
    expect(find.text('2 个在干活'), findsOneWidget);
    expect(find.textContaining('做完'), findsNothing);
    await terms(tester, []);
    expect(find.textContaining('个在干活'), findsNothing);
    expect(find.textContaining('做完'), findsNothing);
  });

  testWidgets('one card rest rows', (tester) async {
    await boot(tester);
    await terms(tester, blocked(4));
    expect(find.byType(PhoneCard), findsOneWidget);
    expect(find.byType(PhoneRow), findsNWidgets(3));
    final first = tester.widget<PhoneCard>(find.byType(PhoneCard)).item.id;
    final third = tester.widget<PhoneRow>(find.byType(PhoneRow).at(2)).item.id;
    await tester.tap(find.byType(PhoneRow).at(2));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PhoneCard), findsOneWidget);
    expect(tester.widget<PhoneCard>(find.byType(PhoneCard)).item.id, third);
    expect(tester.widgetList<PhoneRow>(find.byType(PhoneRow)).map((r) => r.item.id), contains(first));
  });

  testWidgets('at most eight taps', (tester) async {
    await boot(tester);
    await terms(tester, blocked(12));
    expect(find.byType(PhoneCard), findsOneWidget);
    expect(find.byType(PhoneRow), findsNWidgets(5));
    expect(find.text('还有 6 件'), findsOneWidget);
    expect(taps(tester), lessThanOrEqualTo(8));
    await tester.tap(find.text('还有 6 件'));
    await tester.pump();
    expect(find.text('还有 6 件'), findsNothing);
  });

  testWidgets('at most eight taps with came from row', (tester) async {
    await boot(tester, termPort: true);
    await terms(tester, blocked(12));
    await cameFromOpen(tester, 'm1/term:pty:w0');
    nav.notifyListeners();
    await tester.pump();
    expect(find.byType(PhoneRow), findsNWidgets(4));
    expect(find.text('还有 7 件'), findsOneWidget);
    expect(taps(tester), lessThanOrEqualTo(8));
  });

  testWidgets('offline greys reconnect', (tester) async {
    await boot(tester);
    await tester.runAsync(() async {
      s.openOrSwitch('m1', 'Safari', 'Safari');
      for (var i = 0; i < 6; i++) {
        await flush();
      }
    });
    port.emit(const DisconnectedEvent(1, 'host says: taken over by M'));
    await tester.pump();
    expect(find.text('重连'), findsOneWidget);
    PhoneButton btn() => tester.widget<PhoneButton>(find.widgetWithText(PhoneButton, '重连'));
    expect(btn().onPressed, isNotNull);
    await emit(tester, {'event': 'net', 'level': 'down'});
    expect(btn().onPressed, isNull);
    await emit(tester, {'event': 'net', 'level': 'strong'});
    expect(btn().onPressed, isNotNull);
  });

  testWidgets('goLook enters the session', (tester) async {
    await boot(tester, termPort: true);
    await terms(tester, blocked(1));
    await tester.runAsync(() async {
      s.openOrSwitch('m1', 'term:pty:w0', 'w0');
      for (var i = 0; i < 6; i++) {
        await flush();
      }
    });
    await tester.pump();
    await tester.tap(find.text('进去看'));
    await tester.runAsync(flush);
    await tester.pump();
    expect(nav.now, PhoneView.session);
    expect(s.currentKey, 'm1/term:pty:w0');
    expect(nav.entered, 'm1/term:pty:w0');
  });

  List<Map<String, Object?>> many(String kind, String state, int n, {bool unread = false}) =>
      [for (var i = 0; i < n; i++) term('$kind$i', state, unread: unread, msg: '$kind$i')];

  testWidgets('h7 sections only when nothing needs a look', (tester) async {
    await boot(tester);
    await terms(tester, [
      ...many('e', 'error', 2, unread: true),
      ...many('k', 'working', 2),
      ...many('d', 'done', 2, unread: true),
    ]);
    expect(find.text('4 件等你'), findsOneWidget);
    expect(find.text('在干活的'), findsNothing);
    expect(find.text('做完没看的'), findsNothing);
  });

  testWidgets('h7 mode has at most eight taps', (tester) async {
    await boot(tester);
    await terms(tester, [...many('k', 'working', 4), ...many('d', 'done', 3, unread: true)]);
    expect(find.text('没有等你的。'), findsOneWidget);
    expect(find.text('在干活的'), findsOneWidget);
    await cameFromOpen(tester, 'm1/term:pty:k0');
    nav.notifyListeners();
    await tester.pump();
    expect(taps(tester), lessThanOrEqualTo(8));
  });

  testWidgets('waiting list with working and came from stays within eight taps', (tester) async {
    await boot(tester);
    await terms(tester, [...blocked(12), ...many('k', 'working', 2)]);
    await cameFromOpen(tester, 'm1/term:pty:k0');
    nav.notifyListeners();
    await tester.pump();
    expect(taps(tester), lessThanOrEqualTo(8));
  });

  testWidgets('second line scrolls only while the list is on screen', (tester) async {
    await boot(tester);
    await terms(tester, [...blocked(1), ...many('k', 'working', 2)]);
    InkWell line() => tester.widget<InkWell>(find.ancestor(of: find.text('2 个在干活'), matching: find.byType(InkWell)));
    expect(line().onTap, isNull);
    await terms(tester, many('k', 'working', 2));
    expect(line().onTap, isNotNull);
  });

  testWidgets('the last card slides away even when came from clears with it', (tester) async {
    await boot(tester, termPort: true);
    await terms(tester, blocked(1));
    await cameFromOpen(tester, 'm1/term:pty:w0');
    nav.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PhoneCard), findsOneWidget);
    nav.cameFrom = null;
    await terms(tester, []);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PhoneCard), findsOneWidget);
    expect(find.ancestor(of: find.byType(PhoneCard), matching: find.byType(SlideTransition)), findsWidgets);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PhoneCard), findsNothing);
  });

  testWidgets('an unopened terminal is entered only after it opens', (tester) async {
    await boot(tester, termPort: true);
    Map<String, dynamic>? held;
    t.onSend = (m) {
      if (m['cmd'] == 'open') held = m;
    };
    await terms(tester, blocked(1));
    await tester.tap(find.text('进去看'));
    await tester.runAsync(flush);
    await tester.pump();
    expect(held, isNotNull);
    expect(nav.now, PhoneView.home);
    await emit(tester, {'event': 'opened', 'sid': 9, 'id': held!['id'], 'app': held!['app'], 'path': 'lan', 'req': held!['req'], if (held!['embed'] == true) ...{'port': 5009, 'token': 'tk'}});
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await flush();
      }
    });
    await tester.pump();
    expect(nav.now, PhoneView.session);
    expect(s.currentKey, 'm1/term:pty:w0');
  });

  testWidgets('a failed open leaves the user on home', (tester) async {
    await boot(tester, termPort: true);
    t.onSend = (m) {
      if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'offline'});
    };
    await terms(tester, blocked(1));
    await tester.tap(find.text('进去看'));
    await tester.runAsync(flush);
    await tester.pump();
    expect(nav.now, PhoneView.home);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('offline greys goLook of a terminal that is not open', (tester) async {
    await boot(tester, termPort: true);
    await terms(tester, blocked(1));
    await emit(tester, {'event': 'net', 'level': 'down'});
    expect(tester.widget<PhoneButton>(find.widgetWithText(PhoneButton, '进去看')).onPressed, isNull);
  });

  testWidgets('six waiting show every row and no 还有 1 件', (tester) async {
    await boot(tester);
    await terms(tester, blocked(6));
    expect(find.byType(PhoneRow), findsNWidgets(5));
    expect(find.textContaining('还有'), findsNothing);
  });

  testWidgets('tapping a row keeps came from', (tester) async {
    await boot(tester);
    await terms(tester, blocked(2));
    await cameFromOpen(tester, 'm1/term:pty:w0');
    nav.notifyListeners();
    await tester.pump();
    await tester.tap(find.byType(PhoneRow).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(nav.cameFrom, 'm1/term:pty:w0');
  });

  testWidgets('got it on a message marks it handled, and is grey offline', (tester) async {
    final sync = _Sync(tmp.path)..status = StateStatus.connected;
    await boot(tester, sync: sync);
    sync.rows = [
      {'t': 'emit', 'level': 'info', 'eid': 'e1', 'id': 'm1', 'text': 'hi', 'at': 5},
    ];
    sync.push();
    await tester.pump();
    expect(find.text('hi'), findsOneWidget);
    await emit(tester, {'event': 'net', 'level': 'down'});
    expect(tester.widget<PhoneButton>(find.widgetWithText(PhoneButton, '知道了')).onPressed, isNull);
    await emit(tester, {'event': 'net', 'level': 'strong'});
    await tester.tap(find.text('知道了'));
    await tester.pump();
    expect(sync.handled, ['e1']);
    expect(find.text('hi'), findsNothing);
  });

  testWidgets('got it on a resource snoozes it', (tester) async {
    await boot(tester);
    await emit(tester, _load('m1'));
    expect(s.needs.any((n) => n.kind == NeedKind.resource), isTrue);
    await tester.tap(find.text('知道了'));
    await tester.pump();
    expect(s.needs.any((n) => n.kind == NeedKind.resource), isFalse);
    await emit(tester, {'event': 'load', 'id': 'm1', 'gone': true});
  });

  testWidgets('came from row', (tester) async {
    await boot(tester);
    await terms(tester, blocked(1));
    await cameFromOpen(tester, 'm1/term:pty:w0');
    nav.notifyListeners();
    await tester.pump();
    expect(find.textContaining('刚才在：'), findsOneWidget);
    await tester.tap(find.text('进去看'));
    await tester.pump();
    expect(find.textContaining('刚才在：'), findsNothing);
    expect(nav.cameFrom, isNull);
  });

  // A session that is gone (closed, its host gone) has no 刚才在 row: a raw key is nothing to tap.
  testWidgets('came from a gone session shows no row', (tester) async {
    await boot(tester);
    await terms(tester, blocked(1));
    nav.cameFrom = 'm1/term:pty:gone';
    nav.notifyListeners();
    await tester.pump();
    expect(find.textContaining('刚才在'), findsNothing);
    expect(find.textContaining('term:pty:gone'), findsNothing);
  });

  testWidgets('home without service has no empty slots', (tester) async {
    await boot(tester);
    await terms(tester, blocked(1));
    expect(find.textContaining('消息'), findsNothing);
    expect(find.textContaining('0 个'), findsNothing);
    expect(find.byType(PhoneCard), findsOneWidget);
    expect(tester.widget<PhoneCard>(find.byType(PhoneCard)).item.line, isNotEmpty);
  });

  testWidgets('no devices shows add device', (tester) async {
    await boot(tester, noHosts: true);
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('添加设备'), findsOneWidget);
    expect(find.textContaining('件等你'), findsNothing);
  });

  testWidgets('offline keeps last content and greys buttons', (tester) async {
    await boot(tester);
    await terms(tester, blocked(2));
    await emit(tester, {'event': 'net', 'level': 'down'});
    expect(find.byType(PhoneCard), findsOneWidget);
    expect(find.text('连不上，通了自动恢复'), findsOneWidget);
    await emit(tester, {'event': 'net', 'level': 'strong'});
    expect(find.text('连不上，通了自动恢复'), findsNothing);
  });

  testWidgets('reduce motion removes at once', (tester) async {
    await boot(tester, disableAnimations: true);
    await terms(tester, blocked(2));
    expect(find.byType(PhoneCard), findsOneWidget);
    await terms(tester, [blocked(2).last]);
    await tester.pump();
    expect(find.byType(PhoneCard), findsOneWidget);
    expect(find.text('1 件等你'), findsOneWidget);
    await terms(tester, []);
    await tester.pump();
    expect(find.byType(PhoneCard), findsNothing);
  });
}
