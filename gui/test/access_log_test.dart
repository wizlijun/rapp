import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/access_log.dart';
import 'package:rapp/pages/access_log_section.dart';

void main() {
  const ts = '2026-11-12T03:04:05.123Z';
  final local = DateTime.parse(ts).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final shown = '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';

  group('historyRow', () {
    test('a session end shows local time, the self-declared name, path, app, duration', () {
      final r = historyRow({
        'ts': ts,
        'ev': 'session_end',
        'peer': '192.168.1.20:5000',
        'name': 'MacBook-M4',
        'path': 'lan',
        'app': 'com.apple.Safari',
        'sid': 3,
        'secs': 125,
        'up': 10,
        'down': 20,
        'reason': 'closed',
      });
      expect(r.time, shown);
      expect(r.who, 'MacBook-M4（自称）· 192.168.1.20:5000');
      expect(r.path, '局域网');
      expect(r.app, 'com.apple.Safari');
      expect(r.duration, '2分05秒');
      expect(r.result, '结束');
      expect(r.warn, isFalse);
    });

    test('without a name only the address is shown; paths and reasons are translated', () {
      final start = historyRow({'ts': ts, 'ev': 'session_start', 'peer': '1.2.3.4:9', 'path': 'relay', 'app': 'x'});
      expect(start.who, '1.2.3.4:9');
      expect(start.path, '中继');
      expect(start.result, '开始');
      expect(start.duration, '');
      final kicked = historyRow({'ts': ts, 'ev': 'session_end', 'peer': 'p', 'path': 'direct', 'secs': 3725, 'reason': 'kicked'});
      expect(kicked.path, '直连');
      expect(kicked.duration, '1时02分');
      expect(kicked.result, '被断开');
      final broken = historyRow({'ts': ts, 'ev': 'session_end', 'peer': 'p', 'path': 'lan', 'secs': 7, 'reason': 'reset'});
      expect(broken.duration, '7秒');
      expect(broken.result, '中断：reset');
    });

    test('refused auths and failed requests are warnings', () {
      final auth = historyRow({'ts': ts, 'ev': 'auth_fail', 'peer': '5.6.7.8:1', 'name': 'x', 'path': 'direct', 'reason': 'wrong password'});
      expect(auth.who, 'x（自称）· 5.6.7.8:1');
      expect(auth.app, '');
      expect(auth.result, '拒绝：wrong password');
      expect(auth.warn, isTrue);
      final req = historyRow(
          {'ts': ts, 'ev': 'request', 'peer': 'p', 'path': 'lan', 'op': 'open', 'app': 'com.x', 'result': 'missing permission'});
      expect(req.app, 'com.x');
      expect(req.result, '失败：missing permission');
      expect(req.warn, isTrue);
      final list = historyRow({'ts': ts, 'ev': 'request', 'peer': 'p', 'path': 'lan', 'op': 'list_apps', 'result': 'boom'});
      expect(list.app, '（列出应用）');
    });

    test('auto lock rows', () {
      final ok = historyRow({'ts': ts, 'ev': 'auto_lock'});
      expect(ok.result, '远程 app 都已关闭，已自动锁屏');
      expect(ok.warn, isFalse);
      final bad = historyRow({'ts': ts, 'ev': 'auto_lock_failed', 'error': 'forced'});
      expect(bad.result, '自动锁屏失败：forced');
      expect(bad.warn, isTrue);
    });

    test('不锁屏 rows', () {
      final on = historyRow({'ts': ts, 'ev': 'no_lock_set', 'by': 'local', 'on': true});
      expect(on.result, '打开了「不锁屏」');
      expect(on.warn, isFalse);
      final off = historyRow({'ts': ts, 'ev': 'no_lock_set', 'by': '1a2b3c4d', 'peer': 'p', 'name': 'mini', 'on': false});
      expect(off.result, '关掉了「不锁屏」');
      expect(off.who, 'mini（自称）· p');
      expect(off.warn, isFalse);
      final refused = historyRow({'ts': ts, 'ev': 'no_lock_refused', 'peer': 'p', 'reason': 'not supported', 'on': true});
      expect(refused.result, '拒绝改「不锁屏」：not supported');
      expect(refused.warn, isTrue);
      final failed = historyRow({'ts': ts, 'ev': 'no_lock_hold_failed', 'code': 1, 'stderr': 'no display'});
      expect(failed.result, '没能保持唤醒：no display');
      expect(failed.warn, isTrue);
    });

    test('desktop sessions and typed system passwords', () {
      final base = {'ts': ts, 'peer': 'p', 'path': 'lan', 'sid': 3};
      expect(historyRow({...base, 'ev': 'session_start', 'app': 'desktop:'}).app, '桌面');
      expect(historyRow({...base, 'ev': 'session_start', 'app': 'desktop:69733382'}).app, '桌面（其他屏）');
      final unlock = historyRow({'ts': ts, 'ev': 'unlock', 'app': 'desktop:', 'sid': 3});
      expect(unlock.result, '输入了系统密码');
      expect(unlock.app, '桌面');
      expect(unlock.warn, isFalse);
    });

    test('takeover and blocked input rows', () {
      final base = {'ts': ts, 'peer': 'p', 'path': 'lan', 'app': 'x', 'sid': 3};
      final named = historyRow({...base, 'ev': 'session_end', 'reason': 'taken over', 'by': 'b-two'});
      expect(named.result, '被 b-two 接管');
      expect(named.warn, isFalse);
      expect(historyRow({...base, 'ev': 'session_end', 'reason': 'taken over'}).result, '被另一台设备接管');
      final blocked = historyRow({'ts': ts, 'ev': 'input_blocked', 'app': 'x', 'sid': 3, 'by': 'b-two'});
      expect(blocked.result, '输入被挡：b-two 正在操作');
      expect(blocked.warn, isFalse);
      expect(historyRow({'ts': ts, 'ev': 'input_blocked', 'app': 'x', 'sid': 3}).result, '输入被挡：另一台设备 正在操作');
    });

    test('a host refusal (busy, version, token) is a warning, not a session', () {
      final r = historyRow({'ts': ts, 'ev': 'rejected', 'sid': 4, 'reason': 'busy'});
      expect(r.result, '拒绝：busy');
      expect(r.warn, isTrue);
    });

    test('a bad timestamp or missing fields do not throw', () {
      final r = historyRow({'ev': 'session_start'});
      expect(r.time, '');
      expect(r.who, '');
    });
  });

  testWidgets('the section lists rows, colours refusals, and opens the log folder', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), 
      home: Scaffold(
        body: AccessLogSection(
          load: () async => [
            {'ts': ts, 'ev': 'auth_fail', 'peer': '5.6.7.8:1', 'path': 'direct', 'reason': 'wrong password'},
            {'ts': ts, 'ev': 'session_start', 'peer': '192.168.1.20:5', 'name': 'MacBook-M4', 'path': 'lan', 'app': 'com.x'},
          ],
          logDir: '/logs/rapp',
          openFolder: (d) async => opened.add(d),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('访问记录'), findsOneWidget);
    expect(find.textContaining('MacBook-M4（自称）· 192.168.1.20:5'), findsOneWidget);
    final refused = tester.widget<Text>(find.textContaining('拒绝：wrong password'));
    expect(refused.style?.color, isNotNull);

    await tester.tap(find.text('打开日志文件夹'));
    await tester.pump();
    expect(opened, ['/logs/rapp']);
  });

  testWidgets('an empty history says so; a load error is shown', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), 
      home: Scaffold(body: AccessLogSection(load: () async => [], logDir: null, openFolder: (_) async {})),
    ));
    await tester.pumpAndSettle();
    expect(find.text('（还没有记录）'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '打开日志文件夹')).onPressed, isNull);

    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), 
      home: Scaffold(
          body: AccessLogSection(
              key: const ValueKey(2), load: () async => throw Exception('down'), logDir: null, openFolder: (_) async {})),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('读取失败'), findsOneWidget);
  });

  testWidgets('with a limit only the newest rows show, live, and 更多 hands over', (tester) async {
    var events = [
      for (var i = 0; i < 8; i++) {'ts': ts, 'ev': 'session_start', 'peer': '10.0.0.$i:5', 'name': 'peer$i', 'path': 'lan'},
    ];
    final reload = ChangeNotifier();
    addTearDown(reload.dispose);
    var more = 0;
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), 
      home: Scaffold(
        body: SingleChildScrollView(
          child: AccessLogSection(
            load: () async => events,
            logDir: '/logs/rapp',
            openFolder: (_) async {},
            reload: reload,
            limit: 5,
            onMore: () => more++,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      expect(find.textContaining('peer$i（自称）'), findsOneWidget, reason: 'row $i');
    }
    expect(find.textContaining('peer5（自称）'), findsNothing);
    // A new row arrives first; the oldest of the five drops out.
    events = [{'ts': ts, 'ev': 'session_start', 'peer': '10.0.0.99:5', 'name': 'fresh', 'path': 'lan'}, ...events];
    reload.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('fresh（自称）'), findsOneWidget);
    expect(find.textContaining('peer4（自称）'), findsNothing);
    await tester.tap(find.byKey(const Key('access-log-more')));
    expect(more, 1);
  });
}
