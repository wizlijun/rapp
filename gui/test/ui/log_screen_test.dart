import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/log_view.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/log_model.dart';
import 'package:rapp/ui/log_screen.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';

const _ts = '2026-11-18T10:00:00.000Z';

LogEntry ev(String at, Map<String, dynamic> f, {String src = 'service', LogKind? kind, int repeat = 0, String ts = _ts}) =>
    LogEntry(src: src, at: at, raw: jsonEncode({'ts': ts, ...f}), kind: kind, repeat: repeat);

/// [n] plain rows `<p>00`, `<p>01`, … newest first.
List<LogEntry> plain(int n, [String p = 'r']) => [
      for (var i = 0; i < n; i++) ev('$p${i.toString().padLeft(2, '0')}', {'ev': 'service_start', 'n': i}),
    ];

final route = ev('u1', {'lvl': 'warn', 'ev': 'route', 'id': '111', 'path': 'relay', 'result': 'timeout'},
    src: 'hub', kind: LogKind.unreachable);
final rejected =
    ev('f1', {'ev': 'rejected', 'peer': '5.6.7.8:51022', 'path': 'direct', 'reason': 'wrong password'}, kind: LogKind.refused);
final failed = ev('x1', {'lvl': 'warn', 'ev': 'update_failed', 'stage': 'download', 'reason': 'timeout'}, kind: LogKind.fault);

LogPage first({
  List<LogEntry>? events,
  bool more = false,
  Map<LogKind, int> counts = const {LogKind.unreachable: 12, LogKind.refused: 3, LogKind.fault: 1},
  List<String>? launchd,
}) {
  final e = events ?? [route, rejected];
  return LogPage(
    events: e,
    more: more,
    older: e.isEmpty ? null : e.last.at,
    newer: e.isEmpty ? null : e.first.at,
    counts: counts,
    latest: {
      if ((counts[LogKind.unreachable] ?? 0) > 0) LogKind.unreachable: route,
      if ((counts[LogKind.refused] ?? 0) > 0) LogKind.refused: rejected,
      if ((counts[LogKind.fault] ?? 0) > 0) LogKind.fault: failed,
    },
    launchd: launchd,
  );
}

LogPage page(List<LogEntry> e, {bool more = false, bool gap = false}) => LogPage(
      events: e,
      more: more,
      gap: gap,
      older: e.isEmpty ? null : e.last.at,
      newer: e.isEmpty ? null : e.first.at,
    );

class Fake {
  final calls = <(String?, LogQuery)>[];
  Future<LogPage> Function(String? id, LogQuery q) reply = (id, q) async => first();
  Future<LogPage> call(String? id, LogQuery q) {
    calls.add((id, q));
    return reply(id, q);
  }

  LogQuery get last => calls.last.$2;
}

const devices = [('111', 'mini', Lamp.idle), ('222', 'far', Lamp.offline)];

void main() {
  late Fake f;
  setUp(() => f = Fake());

  Future<LogModel> show(
    WidgetTester t, {
    String? device,
    Future<void> Function(String dir)? openFolder,
    VoidCallback? onBack,
  }) async {
    final m = LogModel(fetch: f.call);
    await t.pumpWidget(wrap(
      LogScreen(
        model: m,
        devices: devices,
        onBack: onBack ?? () {},
        openFolder: openFolder ?? (_) async {},
        logDir: '/tmp/rapp-test-logs',
      ),
      disableAnimations: true,
    ));
    unawaited(m.open(device));
    await t.pump();
    await t.pump();
    return m;
  }

  Future<void> end(WidgetTester t, LogModel m) async {
    await t.pumpWidget(const SizedBox());
    m.dispose();
  }

  Finder card(LogKind k) => find.byKey(Key('log-card-${k.wire}'));
  Finder list() => find.descendant(of: find.byKey(const Key('log-list')), matching: find.byType(Scrollable)).first;
  double offset(WidgetTester t) => t.state<ScrollableState>(list()).position.pixels;
  RappTokens tokens(WidgetTester t) => RappTokens.of(t.element(find.byType(LogScreen)));

  testWidgets('opens on 本机 with problems only', (t) async {
    final m = await show(t);
    expect(f.calls.first.$1, isNull);
    expect(f.calls.first.$2.toJson(), {'problems': true, 'tail_launchd': true, 'limit': 200});
    expect(find.text('‹ 返回'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
    expect(find.descendant(of: card(LogKind.unreachable), matching: find.text('12')), findsOneWidget);
    expect(find.descendant(of: card(LogKind.refused), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: card(LogKind.fault), matching: find.text('1')), findsOneWidget);
    expect(find.descendant(of: card(LogKind.unreachable), matching: find.text('连不上')), findsOneWidget);
    expect(find.descendant(of: card(LogKind.refused), matching: find.text('被拒绝')), findsOneWidget);
    expect(find.descendant(of: card(LogKind.fault), matching: find.text('服务出错')), findsOneWidget);
    expect(find.descendant(of: card(LogKind.unreachable), matching: find.text('路由失败 mini · 中继 · timeout')), findsOneWidget);
    expect(find.descendant(of: card(LogKind.refused), matching: find.text('拒绝 5.6.7.8:51022 · wrong password')), findsOneWidget);
    expect(find.descendant(of: card(LogKind.fault), matching: find.text('更新失败 download · timeout')), findsOneWidget);
    expect(find.byKey(const Key('log-row-u1')), findsOneWidget);
    expect(find.byKey(const Key('log-row-f1')), findsOneWidget);
    expect(find.text('24 小时内没有'), findsNothing);
    await end(t, m);

    f.reply = (id, q) async => first(counts: const {LogKind.unreachable: 12, LogKind.refused: 3, LogKind.fault: 0});
    final m2 = await show(t);
    expect(find.descendant(of: card(LogKind.fault), matching: find.text('24 小时内没有')), findsOneWidget);
    final tk = tokens(t);
    Color? color(LogKind k, String s) =>
        t.widget<Text>(find.descendant(of: card(k), matching: find.text(s))).style?.color;
    expect(color(LogKind.fault, '服务出错'), tk.muted);
    expect(color(LogKind.refused, '被拒绝'), isNot(tk.muted));
    await end(t, m2);
  });

  testWidgets('tapping a card filters to that kind and again clears it', (t) async {
    final m = await show(t);
    await t.tap(card(LogKind.refused));
    await t.pump();
    expect(f.last.kind, LogKind.refused);
    expect(f.last.problems, isTrue);
    expect(f.last.tailLaunchd, isTrue);
    expect(m.kind, LogKind.refused);
    await t.tap(card(LogKind.refused));
    await t.pump();
    expect(f.last.kind, isNull);
    expect(m.kind, isNull);
    await end(t, m);
  });

  testWidgets('全部 drops problems; source toggles send src', (t) async {
    final m = await show(t);
    expect(f.last.src, isNull);
    await t.tap(find.byKey(const Key('log-all')));
    await t.pump();
    expect(f.last.problems, isFalse);
    expect(find.text('全部'), findsOneWidget);
    await t.tap(find.byKey(const Key('log-src-hub')));
    await t.pump();
    expect(f.last.src, {'service'});
    expect(f.last.problems, isFalse);
    await t.tap(find.byKey(const Key('log-src-hub')));
    await t.pump();
    expect(f.last.src, isNull);
    await t.tap(find.byKey(const Key('log-problems')));
    await t.pump();
    expect(f.last.problems, isTrue);
    expect(find.text('只看问题'), findsOneWidget);
    await end(t, m);
  });

  testWidgets('search debounces 300 ms then sends q', (t) async {
    final m = await show(t);
    final n = f.calls.length;
    await t.enterText(find.byKey(const Key('log-search')), 'min');
    await t.pump(const Duration(milliseconds: 200));
    await t.enterText(find.byKey(const Key('log-search')), 'mini');
    await t.pump(const Duration(milliseconds: 200));
    expect(f.calls.length, n);
    await t.pump(const Duration(milliseconds: 100));
    expect(f.calls.length, n + 1);
    expect(f.last.q, 'mini');
    expect(f.last.problems, isTrue);
    await end(t, m);
  });

  testWidgets('scrolling to the end loads older with before = older; 没有更早的了 when more is false', (t) async {
    f.reply = (id, q) async => q.before == null ? first(events: plain(40), more: true) : page(plain(5, 'o'));
    final m = await show(t);
    await t.fling(list(), const Offset(0, -5000), 3000);
    await t.pumpAndSettle();
    final older = f.calls.where((c) => c.$2.before != null).toList();
    expect(older, hasLength(1));
    expect(older.single.$2.before, 'r39');
    expect(older.single.$2.tailLaunchd, isFalse);
    expect(older.single.$2.problems, isTrue);
    expect(m.rows, hasLength(45));
    await t.fling(list(), const Offset(0, -5000), 3000);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('log-end')), findsOneWidget);
    expect(find.text('没有更早的了'), findsOneWidget);
    expect(f.calls.where((c) => c.$2.before != null), hasLength(1));
    await end(t, m);
  });

  testWidgets('poll every 5 s adds new rows on top, deduped by at', (t) async {
    final b = ev('b', {'ev': 'session_end', 'peer': '1.2.3.4'});
    final a = ev('a', {'ev': 'session_start', 'peer': '1.2.3.4'});
    f.reply = (id, q) async => first(events: [b, a]);
    final m = await show(t);
    final n = f.calls.length;
    await t.pump(const Duration(seconds: 4));
    expect(f.calls.length, n);
    f.reply = (id, q) async => page([
          ev('d', {'ev': 'service_stop'}),
          ev('c', {'ev': 'service_start'}),
          ev('b', {'ev': 'session_end', 'peer': '1.2.3.4'}, repeat: 2),
        ]);
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(f.calls.length, n + 1);
    expect(f.last.after, 'b');
    expect(f.last.tailLaunchd, isFalse);
    expect(f.last.problems, isTrue);
    expect(m.rows.map((e) => e.at), ['d', 'c', 'b', 'a']);
    expect(m.rows[2].repeat, 2);
    expect(find.textContaining('（又重复 2 次）'), findsOneWidget);
    // The next poll starts from the new newest row.
    f.reply = (id, q) async => page([]);
    await t.pump(const Duration(seconds: 5));
    expect(f.last.after, 'd');
    await end(t, m);
  });

  testWidgets('a poll with a gap reloads the first page', (t) async {
    final m = await show(t);
    f.reply = (id, q) async => q.after != null ? page(plain(3, 'n'), gap: true) : first(events: plain(2, 'z'));
    await t.pump(const Duration(seconds: 5));
    await t.pump();
    expect(f.calls[f.calls.length - 2].$2.after, 'u1');
    expect(f.last.after, isNull);
    expect(f.last.tailLaunchd, isTrue);
    expect(m.rows.map((e) => e.at), ['z00', 'z01']);
    await end(t, m);
  });

  testWidgets('an empty first page is asked for again quietly', (t) async {
    f.reply = (id, q) async => first(events: const []);
    final m = await show(t);
    expect(find.byKey(const Key('log-end')), findsOneWidget);
    final held = Completer<LogPage>();
    f.reply = (id, q) => held.future;
    await t.pump(const Duration(seconds: 5));
    expect(f.last.after, isNull);
    expect(f.last.tailLaunchd, isTrue);
    expect(m.loading, isFalse);
    expect(find.text('读取中…'), findsNothing);
    held.complete(first(events: [route]));
    await t.pump();
    await t.pump();
    expect(m.rows.map((e) => e.at), ['u1']);
    await end(t, m);
  });

  testWidgets('poll does not jump when scrolled', (t) async {
    f.reply = (id, q) async => first(events: plain(40));
    final m = await show(t);
    await t.drag(list(), const Offset(0, -300));
    await t.pump();
    final at = offset(t);
    expect(at, greaterThan(0));
    f.reply = (id, q) async => page(plain(2, 'n'));
    await t.pump(const Duration(seconds: 5));
    await t.pump();
    expect(find.byKey(const Key('log-pending')), findsOneWidget);
    expect(find.text('有 2 条新的'), findsOneWidget);
    expect(m.pendingNew, 2);
    expect(m.rows.first.at, 'r00');
    expect(m.rows, hasLength(40));
    expect(offset(t), at);
    // A later poll with one of the held rows again does not count it twice.
    f.reply = (id, q) async => page([ev('n00', {'ev': 'service_start'}, repeat: 1)]);
    await t.pump(const Duration(seconds: 5));
    await t.pump();
    expect(find.text('有 2 条新的'), findsOneWidget);
    await t.tap(find.byKey(const Key('log-pending')));
    await t.pump();
    expect(m.rows.map((e) => e.at).take(3), ['n00', 'n01', 'r00']);
    expect(m.rows.first.repeat, 1);
    expect(offset(t), 0);
    expect(find.byKey(const Key('log-pending')), findsNothing);
    await end(t, m);
  });

  testWidgets('row opens in place with fields, raw, 复制 copies raw', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final m = await show(t);
    expect(find.text('来源地址'), findsNothing);
    await t.tap(find.byKey(const Key('log-row-f1')));
    await t.pump();
    expect(find.text('来源地址'), findsOneWidget);
    expect(find.text('5.6.7.8:51022'), findsOneWidget);
    expect(find.text('原因'), findsOneWidget);
    expect(find.text('wrong password'), findsOneWidget);
    expect(find.text(rejected.raw), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('看前后 ±1 分钟'), findsOneWidget);
    await t.tap(find.byKey(const Key('log-copy-f1')));
    await t.pump();
    expect(copied, rejected.raw);
    await t.tap(find.byKey(const Key('log-row-f1')));
    await t.pump();
    expect(find.text('来源地址'), findsNothing);
    await end(t, m);
  });

  testWidgets('看前后 shows the ±1 min view with the row highlighted; × returns to the list and scroll position',
      (t) async {
    f.reply = (id, q) async => first(events: plain(40));
    final m = await show(t);
    await t.drag(list(), const Offset(0, -200));
    await t.pump();
    final at = offset(t);
    expect(at, greaterThan(0));
    final target = find.byKey(const Key('log-row-r10'));
    expect(target.hitTestable(), findsOneWidget);
    await t.tap(target);
    await t.pump();
    final hit = m.rows[10];
    f.reply = (id, q) async => LogPage(
          events: [ev('w1', {'ev': 'service_stop'}), hit, ev('w2', {'ev': 'service_start'})],
          more: false,
        );
    await t.tap(find.byKey(const Key('log-around-r10')));
    await t.pump();
    await t.pump();
    expect(f.last.around, 'r10');
    expect(f.last.problems, isFalse);
    expect(f.last.src, isNull);
    expect(f.last.tailLaunchd, isFalse);
    expect(m.aroundOf?.at, 'r10');
    expect(find.byKey(const Key('log-around-bar')), findsOneWidget);
    expect(find.textContaining('前后 1 分钟'), findsOneWidget);
    expect(m.rows.map((e) => e.at), ['w1', 'r10', 'w2']);
    final tk = tokens(t);
    bool lit(String key) => find
        .descendant(
          of: find.byKey(Key(key)),
          matching: find.byWidgetPredicate(
              (w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == tk.tint),
        )
        .evaluate()
        .isNotEmpty;
    expect(lit('log-row-r10'), isTrue);
    expect(lit('log-row-w1'), isFalse);
    // No polling while the window is shown.
    final n = f.calls.length;
    await t.pump(const Duration(seconds: 6));
    expect(f.calls.length, n);
    await t.tap(find.byKey(const Key('log-around-close')));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('log-around-bar')), findsNothing);
    expect(m.aroundOf, isNull);
    expect(m.rows, hasLength(40));
    expect(offset(t), at);
    await end(t, m);
  });

  testWidgets('old device message', (t) async {
    f.reply = (id, q) async {
      if (id == '111') throw HubException('unknown op');
      if (id == '222') throw HubException('connect timed out');
      return first();
    };
    final m = await show(t);
    await t.tap(find.byKey(const Key('log-device-picker')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('log-device-local')), findsOneWidget);
    expect(find.byKey(const Key('log-device-222')), findsOneWidget);
    await t.tap(find.byKey(const Key('log-device-111')));
    await t.pumpAndSettle();
    expect(f.calls.last.$1, '111');
    expect(m.device, '111');
    expect(find.text('对方版本太旧，看不到它的日志'), findsOneWidget);
    expect(find.byKey(const Key('log-row-u1')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('log-device-picker')), matching: find.text('mini')), findsOneWidget);
    unawaited(m.open('222'));
    await t.pump();
    await t.pump();
    expect(find.text('connect timed out'), findsOneWidget);
    expect(find.text('对方版本太旧，看不到它的日志'), findsNothing);
    await end(t, m);
  });

  testWidgets('late reply for previous device is ignored', (t) async {
    final held = Completer<LogPage>();
    f.reply = (id, q) => id == '111' ? held.future : Future.value(first(events: plain(2, id == '222' ? 'b' : 'l')));
    final m = await show(t);
    unawaited(m.open('111'));
    await t.pump();
    unawaited(m.open('222'));
    await t.pump();
    await t.pump();
    held.complete(first(events: plain(2, 'a')));
    await t.pump();
    await t.pump();
    expect(m.device, '222');
    expect(m.rows.map((e) => e.at), ['b00', 'b01']);
    expect(find.byKey(const Key('log-row-a00')), findsNothing);
    expect(find.byKey(const Key('log-row-b00')), findsOneWidget);
    await end(t, m);
  });

  testWidgets('启动输出 toggles the launchd tail; hidden when launchd is null', (t) async {
    f.reply = (id, q) async => first(launchd: ['line one', 'panic: boom']);
    final m = await show(t);
    expect(find.byKey(const Key('log-launchd-toggle')), findsOneWidget);
    expect(find.textContaining('启动输出'), findsOneWidget);
    expect(find.byKey(const Key('log-launchd-text')), findsNothing);
    await t.tap(find.byKey(const Key('log-launchd-toggle')));
    await t.pump();
    expect(find.byKey(const Key('log-launchd-text')), findsOneWidget);
    expect(find.textContaining('panic: boom'), findsOneWidget);
    await t.tap(find.byKey(const Key('log-launchd-toggle')));
    await t.pump();
    expect(find.byKey(const Key('log-launchd-text')), findsNothing);
    await end(t, m);

    f.reply = (id, q) async => first();
    final m2 = await show(t);
    expect(find.byKey(const Key('log-launchd-toggle')), findsNothing);
    await end(t, m2);
  });

  testWidgets('ipad has no source toggles when only hub rows exist', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      f.reply = (id, q) async => first(events: [route]);
      final m = await show(t);
      expect(find.byKey(const Key('log-row-u1')), findsOneWidget);
      expect(find.byKey(const Key('log-src-service')), findsNothing);
      expect(find.byKey(const Key('log-src-hub')), findsNothing);
      expect(f.last.src, isNull);
      await end(t, m);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('ipad controls are at least 48 tall', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      f.reply = (id, q) async => first(events: [route, rejected], more: true, launchd: ['x']);
      final m = await show(t);
      await t.tap(find.byKey(const Key('log-row-f1')));
      await t.pump();
      for (final k in [
        'log-back',
        'log-device-picker',
        'log-search',
        'log-refresh',
        'log-open-folder',
        'log-card-unreachable',
        'log-card-refused',
        'log-card-fault',
        'log-problems',
        'log-all',
        'log-launchd-toggle',
        'log-row-u1',
        'log-copy-f1',
        'log-around-f1',
        'log-load-older',
      ]) {
        expect(t.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48), reason: k);
      }
      await t.tap(find.byKey(const Key('log-around-f1')));
      await t.pump();
      await t.pump();
      expect(t.getSize(find.byKey(const Key('log-around-close'))).height, greaterThanOrEqualTo(48));
      await end(t, m);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('打开文件夹 only for 本机', (t) async {
    final opened = <String>[];
    final m = await show(t, openFolder: (d) async => opened.add(d));
    expect(find.text('打开文件夹'), findsOneWidget);
    await t.tap(find.byKey(const Key('log-open-folder')));
    await t.pump();
    expect(opened, ['/tmp/rapp-test-logs']);
    unawaited(m.open('111'));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('log-open-folder')), findsNothing);
    await end(t, m);
  });

  testWidgets('‹ 返回 calls onBack; ⟳ asks again', (t) async {
    var back = 0;
    final m = await show(t, onBack: () => back++);
    await t.tap(find.byKey(const Key('log-back')));
    expect(back, 1);
    final n = f.calls.length;
    await t.tap(find.byKey(const Key('log-refresh')));
    await t.pump();
    expect(f.calls.length, n + 1);
    expect(f.last.tailLaunchd, isTrue);
    await end(t, m);
  });

  testWidgets('narrow window: cards scroll sideways, no overflow', (t) async {
    t.view.physicalSize = const Size(600, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final m = await show(t);
    expect(t.takeException(), isNull);
    final sideways = find.ancestor(
      of: card(LogKind.fault),
      matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right),
    );
    expect(sideways, findsOneWidget);
    await end(t, m);

    t.view.physicalSize = const Size(1200, 800);
    final m2 = await show(t);
    expect(t.takeException(), isNull);
    expect(
      find.ancestor(
        of: card(LogKind.fault),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right),
      ),
      findsNothing,
    );
    await end(t, m2);
  });
}
