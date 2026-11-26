import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/load_row.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/needs_you.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import 'helpers.dart';

const gb = 1000000000;

/// A load line for [id]: one disk `/` (with terminal a) and one `/Volumes/x` (with terminal b).
Map<String, dynamic> loadEv(String id, List<(String, String, String)> warnings, {int headroom = 50, double cpu = 10}) => {
      'event': 'load', 'id': id, 'at': 1764100000, 'headroom': headroom, 'tightest': 'cpu', 'term': true,
      'items': {'cpu': {'pct': cpu}},
      'disks': [
        {
          'mount': '/', 'total': 100 * gb, 'avail': 6 * gb, 'level': 'warn',
          'paths': [
            {'kind': 'home', 'path': '/Users/x'},
            {'kind': 'term', 'path': '/Users/x/git/rapp', 'term': 'term:pty:a'},
          ],
        },
        {
          'mount': '/Volumes/x', 'total': 100 * gb, 'avail': 60 * gb, 'level': 'normal',
          'paths': [{'kind': 'term', 'path': '/Volumes/x/w', 'term': 'term:pty:b'}],
        },
      ],
      'warnings': [for (final (item, level, text) in warnings) {'item': item, 'level': level, 'text': text}],
      'history': [],
    };

void main() {
  late Directory tmp;
  late FakeTransport t;
  late HubClient hub;
  late MainState s;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> emit(WidgetTester tester, Map<String, dynamic> m) async {
    t.emit(m);
    await tester.runAsync(flush);
    await tester.pump();
  }

  Future<void> setUpState(WidgetTester tester) async {
    // A row with its buttons is tall: room for the popover below the anchor.
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tmp = Directory.systemTemp.createTempSync('needs_you_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': 'm1', 'name': 'mini'},
        {'id': 'm2', 'name': 'box'},
        {'id': 'm3', 'name': 'pi'},
      ],
    });
    await tester.runAsync(flush);
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
    addTearDown(s.dispose);
    // Every request is answered at once, so no hub wait is left running.
    t.onSend = (m) {
      if (m['req'] is int) t.emit({'event': 'error', 'req': m['req'], 'error': 'test: ${m['cmd']}'});
    };
    await tester.pumpWidget(wrap(SizedBox(
      width: 1000,
      height: 1400,
      // As in the top bar: the button is a bar high.
      child: Align(alignment: Alignment.topRight, child: SizedBox(height: 48, child: NeedsYouAnchor(state: s))),
    )));
  }

  Future<void> openNeeds(WidgetTester tester) async {
    s.toggleCorner(Corner.needs);
    await tester.pump();
  }

  Finder inRow(String target, Finder f) => find.descendant(of: find.byKey(Key('need-row-$target')), matching: f);

  testWidgets('new_term_elsewhere_uses_pick', (tester) async {
    await setUpState(tester);
    await emit(tester, loadEv('m1', [('cpu', 'warn', 'CPU 持续 90% 以上')], headroom: 10, cpu: 95));
    await openNeeds(tester);
    expect(find.text('mini CPU 持续 90% 以上'), findsOneWidget);
    expect(inRow('m1\ncpu', find.text('看占用最多的进程')), findsOneWidget);
    expect(inRow('m1\ncpu', find.text('1小时内不再提醒')), findsOneWidget);
    // No other device to go to: no button.
    expect(find.textContaining('上新建终端'), findsNothing);
    await emit(tester, loadEv('m2', [], headroom: 80));
    await emit(tester, loadEv('m3', [], headroom: 60));
    await emit(tester, {
      'event': 'terms', 'id': 'm2', 'terms': [],
      'hosts': [
        {'host': null, 'launchers': ['Terminal']},
      ],
    });
    expect(inRow('m1\ncpu', find.text('到 box 上新建终端')), findsOneWidget);
    await tester.tap(find.byKey(const Key('need-newterm-m1\ncpu')));
    await tester.runAsync(flush);
    await tester.pump();
    final ot = t.sent.where((m) => m['cmd'] == 'open_term').single;
    expect(ot, {'cmd': 'open_term', 'id': 'm2', 'app': 'Terminal', 'req': anything});
    expect(ot.containsKey('from'), isFalse);
    // Its failure is the hint, as 新建's is.
    expect(s.hint, 'test: open_term');
  });

  testWidgets('disk_action_lists_terms_on_that_disk', (tester) async {
    await setUpState(tester);
    await emit(tester, {
      'event': 'terms', 'id': 'm1',
      'terms': [
        {'id': 'term:pty:a', 'name': 'a', 'command': 'zsh', 'activity': 1},
        {'id': 'term:pty:b', 'name': 'b', 'command': 'zsh', 'activity': 1},
      ],
      'hosts': [],
    });
    await emit(tester, loadEv('m1', [('disk:/', 'warn', '磁盘约 40 分钟后写满（/，剩 6%，含 ~/git/rapp）')]));
    await openNeeds(tester);
    expect(inRow('m1\ndisk:/', find.text('看占用最多的进程')), findsNothing);
    expect(find.textContaining('上新建终端'), findsNothing);
    await tester.tap(find.byKey(const Key('need-disk-terms-m1\ndisk:/')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('need-disk-term-term:pty:a')), findsOneWidget);
    expect(find.byKey(const Key('need-disk-term-term:pty:b')), findsNothing);
    await tester.tap(find.byKey(const Key('need-disk-term-term:pty:a')));
    await tester.runAsync(flush);
    await tester.pumpAndSettle();
    final open = t.sent.lastWhere((m) => m['cmd'] == 'open');
    expect((open['id'], open['app']), ('m1', 'term:pty:a'));
  });

  testWidgets('看占用最多的进程 opens the detail with the process list asked', (tester) async {
    await setUpState(tester);
    await emit(tester, loadEv('m1', [('mem', 'warn', '内存只剩 8%')]));
    await openNeeds(tester);
    await tester.tap(find.byKey(const Key('need-top-m1\nmem')));
    await tester.runAsync(flush);
    await tester.pumpAndSettle();
    expect(find.byType(LoadDetail), findsOneWidget);
    expect(t.sent.where((m) => m['cmd'] == 'load' && m['id'] == 'm1' && m['top'] == true), hasLength(1));
    // The device goes: so does the detail.
    await emit(tester, {'event': 'load', 'id': 'm1', 'gone': true});
    await tester.pumpAndSettle();
    expect(find.byType(LoadDetail), findsNothing);
  });

  testWidgets('battery has only 1小时内不再提醒, and it hides the row', (tester) async {
    await setUpState(tester);
    await emit(tester, loadEv('m1', [('battery', 'warn', '电池只剩 18%')]));
    await openNeeds(tester);
    expect(find.text('mini 电池只剩 18%'), findsOneWidget);
    expect(inRow('m1\nbattery', find.byType(TextButton)).evaluate().length +
        inRow('m1\nbattery', find.byType(OutlinedButton)).evaluate().length +
        inRow('m1\nbattery', find.byType(FilledButton)).evaluate().length, 1);
    await tester.tap(find.byKey(const Key('need-snooze-m1\nbattery')));
    await tester.pump();
    expect(find.text('mini 电池只剩 18%'), findsNothing);
    expect(s.prefs.loadSnooze.keys, ['m1\nbattery']);
  });
}
