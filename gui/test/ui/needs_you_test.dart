import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/load_row.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/needs_you.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import 'helpers.dart';

const gb = 1000000000;

/// A load line for [id]: one disk `/` (with terminal a) and one `/Volumes/x` (with terminal b).
/// [top]: the device says it can list its processes.
Map<String, dynamic> loadEv(String id, List<(String, String, String)> warnings,
        {int headroom = 50, double cpu = 10, bool top = false}) => {
      'event': 'load', 'id': id, 'at': 1764100000, 'headroom': headroom, 'tightest': 'cpu', 'term': true,
      if (top) 'top': true,
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
  var now = DateTime(2026, 11, 26, 12);

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
    now = DateTime(2026, 11, 26, 12);
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), clock: () => now);
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

  /// Lets every load go stale, so its stale timer has run before the test ends.
  Future<void> staleLoads(WidgetTester tester) async {
    now = now.add(loadStaleAfter + const Duration(seconds: 1));
    await tester.pump(loadStaleAfter + const Duration(seconds: 1));
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
    // Same path as 新建, so it starts where 新建 would there (term-restore: serve's `last` pick on m2).
    expect(ot, {'cmd': 'open_term', 'id': 'm2', 'app': 'Terminal', 'from': 'last', 'req': anything});
    // Its failure is the hint, as 新建's is.
    expect(s.hint, 'test: open_term');
    await staleLoads(tester);
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
    await staleLoads(tester);
  });

  testWidgets('top_hidden_without_capability: no service lists processes yet, so a busy row does not offer it',
      (tester) async {
    await setUpState(tester);
    await emit(tester, loadEv('m1', [('cpu', 'danger', 'CPU 持续 90% 以上')], headroom: 5, cpu: 99));
    await openNeeds(tester);
    expect(find.text('mini CPU 持续 90% 以上'), findsOneWidget);
    expect(inRow('m1\ncpu', find.text('看占用最多的进程')), findsNothing);
    expect(inRow('m1\ncpu', find.text('1小时内不再提醒')), findsOneWidget);
    // A device that says it can: the action is there (the gate is real).
    await emit(tester, loadEv('m1', [('cpu', 'danger', 'CPU 持续 90% 以上')], headroom: 5, cpu: 99, top: true));
    expect(inRow('m1\ncpu', find.text('看占用最多的进程')), findsOneWidget);
    await staleLoads(tester);
  });

  testWidgets('看占用最多的进程 opens the detail with the process list asked', (tester) async {
    await setUpState(tester);
    await emit(tester, loadEv('m1', [('mem', 'warn', '内存只剩 8%')], top: true));
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

  testWidgets('stale_load_row_goes: no line for more than 20 s takes the row away, with no event', (tester) async {
    await setUpState(tester);
    await emit(tester, loadEv('m1', [('mem', 'warn', '内存只剩 8%')]));
    await openNeeds(tester);
    expect(find.text('mini 内存只剩 8%'), findsOneWidget);
    now = now.add(const Duration(seconds: 21));
    await tester.pump(const Duration(seconds: 21));
    expect(find.text('mini 内存只剩 8%'), findsNothing);
    expect(s.needCount, 0);
  });

  testWidgets('load_error_row_goes: a stream error takes the row away', (tester) async {
    await setUpState(tester);
    await emit(tester, loadEv('m1', [('mem', 'warn', '内存只剩 8%')]));
    await openNeeds(tester);
    expect(find.text('mini 内存只剩 8%'), findsOneWidget);
    await emit(tester, {'event': 'load', 'id': 'm1', 'error': 'connection lost'});
    expect(find.text('mini 内存只剩 8%'), findsNothing);
    await staleLoads(tester);
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
    await staleLoads(tester);
  });

  testWidgets('grey_need_row_is_muted_counted_and_inert', (tester) async {
    await setUpState(tester);
    final dir = Directory.systemTemp.createTempSync('needs_grey');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sync = FakeStateSync(dir.path)..ids['F'] = 'm1';
    final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), stateSync: sync, clock: () => now);
    addTearDown(st.dispose);
    t.emit({'event': 'presence', 'id': 'm1', 'online': true});
    await tester.runAsync(flush);
    t.emit({'event': 'presence', 'id': 'm1', 'online': false});
    await tester.runAsync(flush);
    sync
      ..status = StateStatus.connected
      ..needs = [
        {'fp': 'F', 'id': 'm1', 'session': 't1', 'kind': 'permission', 'since': 5},
      ]
      ..push();
    await tester.pumpWidget(wrap(SizedBox(
      width: 1000,
      height: 1400,
      child: Align(alignment: Alignment.topRight, child: SizedBox(height: 48, child: NeedsYouAnchor(state: st))),
    )));
    st.toggleCorner(Corner.needs);
    await tester.pump();
    final text = st.needs.firstWhere((n) => n.greyWord != null).text;
    expect(find.text('$text · 设备离线'), findsOneWidget);
    expect(tester.widget<Text>(find.text('$text · 设备离线')).style!.color, RappTokens.of(tester.element(find.text('$text · 设备离线'))).muted);
    expect(find.text('打开'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('needs-count'))).data, '${st.needs.length}');
    await tester.tap(find.text('$text · 设备离线'));
    await tester.pump();
    expect(st.currentKey, isNull);
    expect(st.corner, Corner.needs);
  });
}
