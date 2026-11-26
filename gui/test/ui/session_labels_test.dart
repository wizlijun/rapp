// Session labels (spec 2026-11-26-rapp-session-labels-design.md): a title and note a host keeps for its sessions,
// shown on every card of that session, changed from the card's menu, and the labelled sessions not open standing at
// the end of their device's column ready to open or start again.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/labels.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/session_model.dart';
import 'package:rapp/ui/sessions_tab.dart';

import '../fakes.dart';
import 'helpers.dart';

/// A monitor that never connects: the test sets its status and labels, and records the label changes.
class _Mon extends ServiceMonitor {
  _Mon() : super(readToken: () async => null);
  final sets = <List<String>>[];
  final resets = <String>[];

  void put({List<ServiceSession> sessions = const [], LabelTable? table}) {
    status = ServiceStatus(sessions: sessions);
    labels = table;
    notifyListeners();
  }

  @override
  Future<void> setLabel(String app, {required String title, required String note}) async {
    sets.add([app, title, note]);
    labels = LabelTable((labels?.rev ?? 0) + 1, {...?labels?.labels, app: SessionLabel(title: title, note: note)});
    notifyListeners();
  }

  @override
  Future<void> resetLabel(String app) async {
    resets.add(app);
    labels = LabelTable((labels?.rev ?? 0) + 1, {...?labels?.labels}..remove(app));
    notifyListeners();
  }
}

void main() {
  late FakeTransport t;
  late MainState s;
  late Directory tmp;
  var sid = 0;
  late WidgetTester tt;
  final epoch = DateTime(2026, 11, 26, 12);

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session_labels_test');
    sid = 0;
  });
  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await flush();
      }
    });
    await tester.pump();
  }

  /// m1 (mini) online with [apps] open; replies to label changes like a host would.
  Future<void> boot(WidgetTester tester, {List<String> apps = const []}) async {
    tt = tester;
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    t = FakeTransport();
    t.onSend = (m) {
      switch (m['cmd']) {
        case 'hosts':
          t.emit({
            'event': 'hosts',
            'req': m['req'],
            'hosts': [
              {'id': 'm1', 'name': 'mini'},
            ],
          });
        case 'apps':
          t.emit({'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan', 'apps': []});
        case 'open':
          t.emit({'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req']});
        case 'set_label':
          t.emit({'event': 'label_set', 'req': m['req'], 'id': m['id'], 'rev': 9});
        case 'reset_label':
          t.emit({'event': 'label_reset', 'req': m['req'], 'id': m['id'], 'rev': 9});
      }
    };
    s = MainState(hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), clock: () => epoch);
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await flush();
      }
      for (final a in apps) {
        s.openOrSwitch('m1', a, a);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      }
    });
  }

  /// m1's watch pushes its table [labels] at [rev]; the screen has it on return.
  Future<void> table(int rev, Map<String, Map<String, String>> labels) async {
    t.emit({'event': 'labels', 'id': 'm1', 'rev': rev, 'labels': labels});
    await settle(tt);
  }

  Future<void> showOverview(WidgetTester tester, {ServiceMonitor? monitor}) async {
    s.toggleOverview();
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 1194,
          height: 700,
          child: Overview(state: s, monitor: monitor),
        ),
      ),
    );
    await tester.pump();
  }

  Finder inside(String key, Finder f) => find.descendant(of: find.byKey(Key(key)), matching: f);

  Future<void> rightClick(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  testWidgets('an open session shows its label; one not open stands at the end with 打开 and opens on tap', (
    tester,
  ) async {
    await boot(tester, apps: ['a', 'c']);
    await table(1, {
      'a': {'title': '写作', 'note': '长期写那本书'},
      'b': {'title': '查资料', 'note': ''},
    });
    await showOverview(tester);
    expect(inside('block-m1/a', find.text('写作')), findsOneWidget);
    expect(inside('block-m1/a', find.text('长期写那本书')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('frame-block-m1/a'))).height, 72);
    expect(tester.getSize(find.byKey(const Key('frame-block-m1/c'))).height, 56);
    // b is not open: last in the column, said so, and not counted.
    final order = [
      for (final k in ['a', 'c', 'b']) tester.getTopLeft(find.byKey(Key('block-m1/$k'))).dy,
    ];
    expect(order, orderedEquals([...order]..sort()));
    expect(inside('block-m1/b', find.text('查资料')), findsOneWidget);
    expect(inside('block-m1/b', find.text('没有打开')), findsOneWidget);
    expect(inside('block-m1/b', find.text('打开')), findsOneWidget);
    expect(s.entries.map((e) => e.app), ['a', 'c']);

    await tester.tap(find.byKey(const Key('block-m1/b')));
    await settle(tester);
    expect(t.sent.where((m) => m['cmd'] == 'open').map((m) => m['app']), ['a', 'c', 'b']);
    expect(s.entries.map((e) => e.app), containsAll(['a', 'b', 'c']));
    expect(s.listed.where((e) => e.app == 'b'), hasLength(1));
  });

  testWidgets('a labelled terminal that is gone says CLI · 已停止 and 启动, and starts a new one that takes its label', (
    tester,
  ) async {
    await boot(tester);
    s.hub!.termLists['m1'] = TermList(
      'm1',
      terms: const [],
      hosts: [
        TermHost(null, launchers: const ['Terminal']),
      ],
    );
    final inner = t.onSend!;
    t.onSend = (m) {
      if (m['cmd'] == 'open_term') {
        t.emit({'event': 'term_created', 'req': m['req'], 'id': m['id'], 'term': 'term:pty:new'});
      } else if (m['cmd'] == 'terms') {
        t.emit({
          'event': 'terms',
          'req': m['req'],
          'id': m['id'],
          'terms': [],
          'hosts': [
            {
              'host': null,
              'launchers': ['Terminal'],
            },
          ],
        });
      } else {
        inner(m);
      }
    };
    await table(1, {
      'term:pty:old': {'title': '后端', 'note': 'cargo watch'},
    });
    await showOverview(tester);
    const key = 'block-m1/term:pty:old';
    expect(inside(key, find.text('后端')), findsOneWidget);
    expect(inside(key, find.text('CLI · 已停止')), findsOneWidget);
    expect(inside(key, find.text('启动')), findsOneWidget);

    await tester.tap(find.byKey(const Key(key)));
    await settle(tester);
    final open = t.sent.singleWhere((m) => m['cmd'] == 'open_term');
    expect(open['label_from'], 'term:pty:old');
    expect(s.hint, contains('原来的目录没有记下，已在家目录新开'));
  });

  testWidgets('the card menu: none before the table comes; edit checks what is typed; 还原 clears the label', (
    tester,
  ) async {
    await boot(tester, apps: ['a']);
    await showOverview(tester);
    await rightClick(tester, 'block-m1/a');
    expect(find.byKey(const Key('label-edit')), findsNothing);

    await table(1, {});
    await tester.pump();
    await rightClick(tester, 'block-m1/a');
    expect(find.byKey(const Key('label-reset')), findsNothing, reason: 'nothing to undo without a label');
    await tester.tap(find.byKey(const Key('label-edit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('留空用默认'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('label-title')), 'x' * 65);
    await tester.tap(find.byKey(const Key('label-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('label-error')), findsOneWidget);
    expect(find.text('标题最多 64 个字'), findsOneWidget);
    expect(t.sent.where((m) => m['cmd'] == 'set_label'), isEmpty);

    await tester.enterText(find.byKey(const Key('label-title')), '写作');
    await tester.enterText(find.byKey(const Key('label-note')), '第二稿');
    await tester.tap(find.byKey(const Key('label-save')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('label-title')), findsNothing, reason: 'the dialog closes once saved');
    final set = t.sent.singleWhere((m) => m['cmd'] == 'set_label');
    expect((set['id'], set['app'], set['title'], set['note']), ('m1', 'a', '写作', '第二稿'));

    await table(2, {
      'a': {'title': '写作', 'note': '第二稿'},
    });
    await tester.pump();
    expect(inside('block-m1/a', find.text('写作')), findsOneWidget);
    await rightClick(tester, 'block-m1/a');
    await tester.tap(find.byKey(const Key('label-reset')));
    await settle(tester);
    expect(t.sent.singleWhere((m) => m['cmd'] == 'reset_label')['app'], 'a');
    expect(s.hint, contains('已还原'));
    await table(3, {});
    await tester.pump();
    expect(inside('block-m1/a', find.text('写作')), findsNothing);
  });

  testWidgets('a reset takes a labelled session that is not open off the list; a device without labels has no menu', (
    tester,
  ) async {
    await boot(tester, apps: ['a']);
    await table(1, {
      'b': {'title': '查资料', 'note': ''},
    });
    await showOverview(tester);
    expect(find.byKey(const Key('block-m1/b')), findsOneWidget);
    await table(2, {});
    await tester.pump();
    expect(find.byKey(const Key('block-m1/b')), findsNothing);
    t.emit({'event': 'labels', 'id': 'm1', 'unsupported': true});
    await settle(tester);
    await rightClick(tester, 'block-m1/a');
    expect(find.byKey(const Key('label-edit')), findsNothing);
  });

  testWidgets('the side panel shows the same title and note, and the label-less default name on standby', (
    tester,
  ) async {
    await boot(tester, apps: ['a']);
    await table(1, {
      'a': {'title': '写作', 'note': '长期写那本书'},
      'b': {'title': '', 'note': '只有备注'},
    });
    await tester.pumpWidget(wrap(SizedBox(width: 360, height: 700, child: SessionsTab(state: s))));
    await tester.pump();
    expect(inside('session-m1/a', find.text('写作')), findsOneWidget);
    expect(inside('session-m1/a', find.text('长期写那本书')), findsOneWidget);
    expect(inside('session-m1/b', find.text('只有备注')), findsOneWidget);
    expect(s.groups.last.entries.last.standby, Standby.open);
  });

  testWidgets(
    '本机: an inbound card shows this machine\'s label and edits it; labelled sessions nobody is in list below',
    (tester) async {
      await boot(tester);
      final m = _Mon()
        ..put(
          sessions: [ServiceSession(1, 'm1', 'term:pty:k', 'relay', epoch.millisecondsSinceEpoch ~/ 1000 - 5)],
          table: const LabelTable(1, {
            'term:pty:k': SessionLabel(title: '服务器', note: '别关'),
            'com.apple.Safari': SessionLabel(title: '查文档'),
          }),
        );
      await showOverview(tester, monitor: m);
      expect(inside('inbound-1', find.text('服务器')), findsOneWidget);
      expect(inside('inbound-1', find.text('别关')), findsOneWidget);
      expect(find.byKey(const Key('inbound-kick-1')), findsOneWidget);
      expect(inside('column-local', find.text('有标注的会话 · 1')), findsOneWidget);
      expect(inside('local-label-com.apple.Safari', find.text('查文档')), findsOneWidget);

      await rightClick(tester, 'inbound-1');
      await tester.tap(find.byKey(const Key('label-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('label-title')), '跳板机');
      await tester.tap(find.byKey(const Key('label-save')));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(m.sets.single, ['term:pty:k', '跳板机', '别关']);
      expect(inside('inbound-1', find.text('跳板机')), findsOneWidget);

      await rightClick(tester, 'local-label-com.apple.Safari');
      await tester.tap(find.byKey(const Key('label-reset')));
      await settle(tester);
      expect(m.resets.single, 'com.apple.Safari');
      expect(find.byKey(const Key('local-label-com.apple.Safari')), findsNothing);
    },
  );
}
