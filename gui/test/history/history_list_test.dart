import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/history/history_list.dart';
import 'package:rapp/history/input_history.dart';
import 'package:rapp/paths.dart';

import '../ui/helpers.dart';
import '../ui/platform_helpers.dart';
import 'input_history_test.dart' show rec;

void main() {
  late Directory tmp;
  late DataDir data;
  final now = DateTime(2026, 11, 15, 15, 0);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('history_list_test');
    data = DataDir(tmp.path);
    Directory(data.localDir).createSync(recursive: true);
    File('${data.localDir}/service.json').writeAsStringSync('{"id":"dev1"}');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  void day(String dev, String d, List<Object> lines) {
    final f = File('${data.inputsDir(dev)}/$d.jsonl');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(lines.map((l) => '${jsonEncode(l)}\n').join());
  }

  Future<InputHistory> load(WidgetTester tester) async {
    final h = InputHistory(data: () => data);
    await tester.runAsync(h.refresh);
    addTearDown(h.dispose);
    return h;
  }

  Future<void> show(WidgetTester tester, InputHistory h,
      {String? session, String? host, void Function(String)? onPut}) async {
    // Opening the list refreshes, which is real IO: let it run in real time.
    await tester.runAsync(() => tester.pumpWidget(wrap(SizedBox(
          width: 600,
          height: 1600,
          child: SingleChildScrollView(
            child: InputHistoryList(history: h, session: session, host: host, onPut: onPut, clock: () => now),
          ),
        ))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('search field is 40 tall on macOS, like the log search', (tester) async {
    await onPlatform(TargetPlatform.macOS, () async {
      final h = await load(tester);
      await show(tester, h);
      expect(
          tester.getSize(find.descendant(of: find.byKey(const Key('history-search')), matching: find.byType(InputDecorator))).height,
          40);
    });
  });

  testWidgets('search finds a three-day-old entry and puts it into the editor', (tester) async {
    day('dev1', '2026-11-12', [rec('01A', '2026-11-12T10:30:00+09:00', '跑一下部署脚本\n第二行')]);
    day('dev1', '2026-11-15', [rec('01B', '2026-11-15T09:05:00+09:00', '别的')]);
    final h = await load(tester);
    String? put;
    await show(tester, h, onPut: (t) => put = t);
    await tester.enterText(find.byKey(const Key('history-search')), '部署');
    await tester.pump();
    expect(find.byKey(const Key('history-01A')), findsOneWidget);
    expect(find.byKey(const Key('history-01B')), findsNothing);
    expect(find.text('跑一下部署脚本'), findsOneWidget); // first line only
    expect(find.text('mac · 终端 · agent — zsh'), findsOneWidget);
    expect(find.text('从记录里去掉'), findsOneWidget);
    expect(find.text('git 历史里还在'), findsOneWidget);
    await tester.tap(find.byKey(const Key('put-01A')));
    expect(put, '跑一下部署脚本\n第二行');
  });

  testWidgets('time is HH:mm today and M月d日 HH:mm on other days', (tester) async {
    final today = DateTime(2026, 11, 15, 9, 5).toIso8601String();
    final old = DateTime(2026, 11, 12, 23, 40).toIso8601String();
    day('dev1', '2026-11-15', [rec('01B', today, 'a')]);
    day('dev1', '2026-11-12', [rec('01A', old, 'b')]);
    final h = await load(tester);
    await show(tester, h);
    expect(find.text('09:05'), findsOneWidget);
    expect(find.text('11月12日 23:40'), findsOneWidget);
  });

  testWidgets('scopes narrow to this session and this host', (tester) async {
    day('dev1', '2026-11-15', [
      rec('01A', '2026-11-15T09:00:00+09:00', 'in session'),
      rec('01B', '2026-11-15T09:01:00+09:00', 'same host', session: 'h1/other'),
      rec('01C', '2026-11-15T09:02:00+09:00', 'elsewhere', session: 'h2/x'),
    ]);
    final h = await load(tester);
    await show(tester, h, session: 'h1/com.apple.Terminal', host: 'h1');
    expect(find.byKey(const Key('history-01A')), findsOneWidget); // default: the narrowest
    expect(find.byKey(const Key('history-01B')), findsNothing);
    await tester.tap(find.byKey(const Key('scope-host')));
    await tester.pump();
    expect(find.byKey(const Key('history-01B')), findsOneWidget);
    expect(find.byKey(const Key('history-01C')), findsNothing);
    await tester.tap(find.byKey(const Key('scope-all')));
    await tester.pump();
    expect(find.byKey(const Key('history-01C')), findsOneWidget);

    // Without a session the scope cannot be picked and the default is the host.
    await tester.pumpWidget(const SizedBox());
    await show(tester, h, host: 'h1');
    expect(find.byKey(const Key('history-01B')), findsOneWidget);
    expect(find.byKey(const Key('history-01C')), findsNothing);
    await tester.tap(find.byKey(const Key('scope-session')), warnIfMissed: false);
    await tester.pump();
    expect(find.byKey(const Key('history-01C')), findsNothing);
    expect(find.byKey(const Key('history-01B')), findsOneWidget);
  });

  testWidgets('records from another device show but cannot be removed', (tester) async {
    day('dev2', '2026-11-15', [rec('01A', '2026-11-15T09:00:00+09:00', 'theirs', from: 'dev2')]);
    day('dev1', '2026-11-15', [rec('01B', '2026-11-15T09:01:00+09:00', 'mine')]);
    final h = await load(tester);
    await show(tester, h);
    expect(find.byKey(const Key('history-01A')), findsOneWidget);
    expect(find.byKey(const Key('remove-01A')), findsNothing);
    expect(find.byKey(const Key('remove-01B')), findsOneWidget);
    expect(find.text('git 历史里还在'), findsOneWidget);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied.add((c.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.byKey(const Key('copy-01A')));
    expect(copied, ['theirs']);
  });

  testWidgets('removing takes the entry out of the list and the file', (tester) async {
    day('dev1', '2026-11-15', [
      rec('01A', '2026-11-15T09:00:00+09:00', 'keep'),
      rec('01B', '2026-11-15T09:01:00+09:00', 'drop'),
    ]);
    final h = await load(tester);
    await show(tester, h);
    await tester.tap(find.byKey(const Key('remove-01B')));
    for (var i = 0; i < 20; i++) {
      // The fake clock holds the awaits of the file IO back; each round lets one more through.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byKey(const Key('history-01B')), findsNothing);
    expect(find.byKey(const Key('history-01A')), findsOneWidget);
    expect(File('${data.inputsDir('dev1')}/2026-11-15.jsonl').readAsStringSync(), isNot(contains('01B')));
  });

  testWidgets('drafts are marked 没发出', (tester) async {
    day('dev1', '2026-11-15', [
      rec('01A', '2026-11-15T09:00:00+09:00', 'half', kind: 'draft'),
      rec('01B', '2026-11-15T09:01:00+09:00', 'full'),
    ]);
    final h = await load(tester);
    await show(tester, h);
    expect(find.text('没发出'), findsOneWidget);
    expect(find.byKey(const Key('draft-01A')), findsOneWidget);
  });

  testWidgets('shows 200 at a time with 再显示 200 条', (tester) async {
    day('dev1', '2026-11-15', [
      for (var i = 0; i < 250; i++)
        rec('id${i.toString().padLeft(3, '0')}', '2026-11-15T09:00:${(i % 60).toString().padLeft(2, '0')}+09:00', 'x$i'),
    ]);
    final h = await load(tester);
    await show(tester, h);
    expect(find.textContaining(RegExp(r'^x\d+$')), findsNWidgets(200));
    await tester.ensureVisible(find.byKey(const Key('history-more')));
    await tester.tap(find.byKey(const Key('history-more')));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^x\d+$')), findsNWidgets(250));
    expect(find.byKey(const Key('history-more')), findsNothing);
  });

  testWidgets('opening the list reads the record', (tester) async {
    final h = InputHistory(data: () => data);
    addTearDown(h.dispose);
    day('dev1', '2026-11-15', [rec('01A', '2026-11-15T09:00:00+09:00', 'late')]);
    await show(tester, h);
    expect(find.byKey(const Key('history-01A')), findsOneWidget);
  });
}
