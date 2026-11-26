import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/controls.dart' show RappButton;
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/sessions_tab.dart';
import 'package:rapp/ui/terms_entry.dart';
import 'package:rapp/ui/workspace_store.dart' show AppRef;
import 'package:rapp/ui/term_restore_dialog.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late MainState s;
  late Directory tmp;
  String? restoreError;
  // A restore that stops after the first key: the device's words, the first terminal open.
  String? restoreStop;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Map<String, dynamic> saved(String key, String name, {String? prog, int? at, bool boot = false}) =>
      {'key': key, 'name': name, 'prog': ?prog, 'saved': at ?? now() - 7200, 'boot': boot};

  List<Map<String, dynamic>> savedRows = [];
  List<Map<String, dynamic>> liveRows = [];

  Map<String, dynamic> termsEvent([Object? req]) => {
        'event': 'terms',
        'req': ?req,
        'id': '111',
        'path': 'lan',
        'terms': liveRows,
        'hosts': [
          {'host': null, 'launchers': ['Terminal'], 'saved': savedRows},
        ],
      };

  Future<void> listed() async {
    t.emit(termsEvent());
    await pump();
  }

  setUp(() async {
    restoreError = null;
    restoreStop = null;
    savedRows = [];
    liveRows = [];
    tmp = Directory.systemTemp.createTempSync('term_restore_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await pump();
    t.onSend = (m) {
      final req = m['req'];
      switch (m['cmd']) {
        case 'open':
          t.emit({'event': 'opened', 'req': req, 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan'});
        case 'open_term':
          t.emit({'event': 'term_created', 'req': req, 'id': '111', 'term': 'term:pty:n'});
        case 'restore_terms':
          if (restoreError != null) return t.emit({'event': 'error', 'req': req, 'error': restoreError});
          if (restoreStop != null) {
            final k = m['keys'].first;
            liveRows = [
              {'id': 'term:pty:$k', 'name': k, 'command': 'zsh', 'activity': 1},
            ];
            return t.emit({'event': 'terms_restored', 'req': req, 'id': m['id'], 'terms': ['term:pty:$k'], 'error': restoreStop});
          }
          liveRows = [
            for (final k in m['keys']) {'id': 'term:pty:$k', 'name': k, 'command': 'zsh', 'activity': 1},
          ];
          t.emit({'event': 'terms_restored', 'req': req, 'id': m['id'], 'terms': [for (final k in m['keys']) 'term:pty:$k']});
        case 'forget_terms':
          t.emit({'event': 'terms_forgotten', 'req': req, 'id': m['id']});
        case 'terms':
          t.emit(termsEvent(req));
      }
    };
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs());
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  const terms = AppRef('111', termsEntry, termsEntryName);

  test('term_list_parses_saved', () async {
    savedRows = [
      saved('a', 'rapp', prog: 'claude', at: 1700000000, boot: true),
      saved('b', 'shell'),
      {'key': 1, 'name': 'bad'},
      {'name': 'nokey'},
    ];
    await listed();
    final h = hub.termLists['111']!.hosts.single;
    expect(h.saved.map((x) => x.key), ['a', 'b']);
    expect(h.saved[0].name, 'rapp');
    expect(h.saved[0].prog, 'claude');
    expect(h.saved[0].saved, 1700000000);
    expect(h.saved[0].boot, isTrue);
    expect(h.saved[1].prog, isNull);
    expect(h.saved[1].boot, isFalse);
  });

  test('old host row has no saved', () async {
    t.emit({
      'event': 'terms',
      'id': '111',
      'terms': [],
      'hosts': [
        {'host': null, 'launchers': ['Terminal']},
      ],
    });
    await pump();
    expect(hub.termLists['111']!.hosts.single.saved, isEmpty);
    expect(s.savedTerms('111'), isEmpty);
  });

  test('favorite_verb_orders_open_restore_new', () async {
    s.prefs.termOpen['111'] = 'text';
    // A live terminal with no session here: 打开.
    liveRows = [
      {'id': 'term:pty:l', 'name': 'l', 'command': 'zsh', 'activity': 1},
    ];
    savedRows = [saved('a', 'a', boot: true)];
    await listed();
    expect(s.favoriteVerb(terms), '打开');
    // Nothing live, a saved one from before boot: 恢复.
    liveRows = [];
    await listed();
    expect(s.favoriteVerb(terms), '恢复');
    // Only a saved one from after boot: 新建.
    savedRows = [saved('a', 'a')];
    await listed();
    expect(s.favoriteVerb(terms), '新建');
    // Other tiles always say 打开.
    expect(s.favoriteVerb(const AppRef('111', 'com.apple.Notes', 'Notes')), '打开');
  });

  Future<void> host(WidgetTester tester) async {
    await tester.pumpWidget(wrap(Builder(
      builder: (c) => TextButton(key: const Key('go'), onPressed: () => showTermRestore(c, s, '111'), child: const Text('go')),
    )));
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.runAsync(listed);
    await host(tester);
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
  }

  bool checked(WidgetTester tester, String key) =>
      tester.widget<Checkbox>(find.descendant(of: find.byKey(Key('restore-row-$key')), matching: find.byType(Checkbox))).value!;

  testWidgets('dialog_checks_boot_rows_only', (tester) async {
    savedRows = [saved('a', 'rapp', prog: 'claude', boot: true), saved('b', 'train', prog: 'python', boot: true), saved('c', 'shell')];
    await openDialog(tester);
    expect(find.text('恢复上次的终端 · mini'), findsOneWidget);
    expect(checked(tester, 'a'), isTrue);
    expect(checked(tester, 'b'), isTrue);
    expect(checked(tester, 'c'), isFalse);
    expect(find.text('rapp  claude  2 小时前'), findsOneWidget);
    expect(find.text('shell  —  2 小时前'), findsOneWidget);
    final labels = ['全部清掉', '新建', '取消', '恢复所选'];
    final xs = [for (final l in labels) tester.getTopLeft(find.text(l)).dx];
    expect(xs, [...xs]..sort());
    // Nothing ticked: 恢复所选 is off.
    for (final k in ['a', 'b']) {
      await tester.tap(find.byKey(Key('restore-row-$k')));
    }
    await tester.pump();
    expect(tester.widget<RappButton>(find.byKey(const Key('restore-ok'))).onPressed, isNull);
  });

  testWidgets('dialog_shows_no_directory', (tester) async {
    // The model has no directory at all; every text in the dialog is free of a slash.
    savedRows = [saved('a', 'rapp', prog: 'claude', boot: true), saved('b', 'shell')];
    await openDialog(tester);
    final texts = [for (final w in tester.widgetList<Text>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)))) w.data ?? ''];
    expect(texts, isNotEmpty);
    expect(texts.where((x) => x.contains('/')), isEmpty);
  });

  testWidgets('restore_selected_sends_keys_and_app', (tester) async {
    savedRows = [saved('a', 'rapp', boot: true), saved('b', 'train', boot: true), saved('c', 'shell')];
    s.prefs.termApp['111'] = 'Terminal';
    await openDialog(tester);
    await tester.tap(find.byKey(const Key('restore-row-b')));
    await tester.tap(find.byKey(const Key('restore-row-c')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('restore-ok')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await pump();
      }
    });
    final m = t.sent.firstWhere((m) => m['cmd'] == 'restore_terms');
    expect(m, {'cmd': 'restore_terms', 'id': '111', 'keys': ['a', 'c'], 'app': 'Terminal', 'req': anything});
    expect(t.sent.where((m) => m['cmd'] == 'open').map((m) => m['app']), ['term:pty:a', 'term:pty:c']);
  });

  test('restore_hint_counts_and_selects_first', () async {
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort(), termPort: FakeTermSessionPort());
    savedRows = [saved('a', 'rapp', boot: true), saved('b', 'train', boot: true)];
    await listed();
    await s.restoreSaved('111', ['a', 'b']);
    expect(s.hint, '已恢复 2 个终端');
    await pump();
    await pump();
    expect(s.currentKey, '111/term:pty:a');
  });

  test('restore_stopped_part_way_opens_what_did_and_says_why', () async {
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort(), termPort: FakeTermSessionPort());
    savedRows = [saved('a', 'rapp', boot: true), saved('b', 'train', boot: true)];
    restoreStop = 'no shell to start';
    await listed();
    await s.restoreSaved('111', ['a', 'b']);
    expect(s.hint, 'no shell to start');
    await pump();
    await pump();
    expect(t.sent.where((m) => m['cmd'] == 'open').map((m) => m['app']), ['term:pty:a']);
    expect(s.currentKey, '111/term:pty:a');
  });

  test('restore_with_no_keys_sends_nothing', () async {
    await listed();
    await s.restoreSaved('111', []);
    expect(t.sent.where((m) => m['cmd'] == 'restore_terms'), isEmpty);
  });

  testWidgets('restore_failure_shows_hint_and_keeps_rest', (tester) async {
    savedRows = [saved('a', 'rapp', boot: true), saved('b', 'train', boot: true)];
    restoreError = 'Terminal did not answer: on that Mac, allow rApp to control Terminal and System Events';
    await openDialog(tester);
    await tester.tap(find.byKey(const Key('restore-ok')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await pump();
      }
    });
    expect(s.hint, contains('允许 rApp 控制'));
    expect(t.sent.where((m) => m['cmd'] == 'open'), isEmpty);
    // The list was refreshed and still holds both.
    expect(t.sent.where((m) => m['cmd'] == 'terms'), isNotEmpty);
    expect(s.savedTerms('111').map((x) => x.key), ['a', 'b']);
    // Past the wait card's timers.
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('forget_all_sends_every_key', (tester) async {
    savedRows = [saved('a', 'rapp', boot: true), saved('b', 'train'), saved('c', 'shell')];
    await openDialog(tester);
    await tester.tap(find.byKey(const Key('restore-forget')));
    await tester.pumpAndSettle();
    await tester.runAsync(pump);
    expect(t.sent.firstWhere((m) => m['cmd'] == 'forget_terms'),
        {'cmd': 'forget_terms', 'id': '111', 'keys': ['a', 'b', 'c'], 'req': anything});
    expect(t.sent.where((m) => m['cmd'] == 'restore_terms'), isEmpty);
  });

  testWidgets('new_runs_the_new_terminal_path', (tester) async {
    s.prefs.termOpen['111'] = 'text';
    savedRows = [saved('a', 'rapp', boot: true)];
    await openDialog(tester);
    await tester.tap(find.byKey(const Key('restore-new')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await pump();
      }
    });
    expect(t.sent.where((m) => m['cmd'] == 'restore_terms'), isEmpty);
    expect(t.sent.firstWhere((m) => m['cmd'] == 'open_term'),
        {'cmd': 'open_term', 'id': '111', 'app': 'Terminal', 'from': 'last', 'req': anything});
  });

  testWidgets('sessions_tab_favorite_says_restore_and_opens_dialog', (tester) async {
    s.prefs.termOpen['111'] = 'text';
    savedRows = [saved('a', 'rapp', prog: 'claude', boot: true)];
    await tester.runAsync(listed);
    s.toggleFavorite('111', termsEntry, termsEntryName);
    await tester.pumpWidget(wrap(SizedBox(width: 330, height: 400, child: SessionsTab(state: s))));
    await tester.pump();
    final fav = find.byKey(const Key('favorite-111/$termsEntry'));
    expect(find.descendant(of: fav, matching: find.text('恢复')), findsOneWidget);
    await tester.tap(fav);
    await tester.pumpAndSettle();
    expect(find.text('恢复上次的终端 · mini'), findsOneWidget);
    expect(t.sent.where((m) => m['cmd'] == 'restore_terms' || m['cmd'] == 'open_term'), isEmpty);
  });

  testWidgets('linux_omarchy_launcher_restores_and_creates_from_last', (tester) async {
    Future<void> emitLinuxTerms([Object? req]) async {
      t.emit({
        'event': 'terms',
        'req': ?req,
        'id': '111',
        'path': 'lan',
        'terms': liveRows,
        'hosts': [
          {
            'host': null,
            'launchers': ['ghostty', 'kitty'],
            'shells': [
              {'name': 'bash', 'path': '/usr/bin/bash', 'default': true},
            ],
            'saved': savedRows,
          },
        ],
      });
      await pump();
    }

    final prevOnSend = t.onSend;
    t.onSend = (m) {
      if (m['cmd'] == 'terms') {
        emitLinuxTerms(m['req']);
        return;
      }
      prevOnSend?.call(m);
    };
    savedRows = [saved('a', 'rapp', prog: 'claude', boot: true), saved('b', 'shell')];
    await tester.runAsync(emitLinuxTerms);
    s.toggleFavorite('111', termsEntry, termsEntryName);
    await tester.pumpWidget(Theme(
      data: ThemeData(platform: TargetPlatform.linux),
      child: wrap(SizedBox(width: 330, height: 400, child: SessionsTab(state: s))),
    ));
    await tester.pump();
    final fav = find.byKey(const Key('favorite-111/$termsEntry'));
    expect(find.descendant(of: fav, matching: find.text('恢复')), findsOneWidget);
    await tester.tap(fav);
    await tester.pumpAndSettle();
    expect(find.text('恢复上次的终端 · mini'), findsOneWidget);
    await tester.tap(find.byKey(const Key('restore-ok')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await pump();
      }
    });
    expect(
      t.sent.firstWhere((m) => m['cmd'] == 'restore_terms'),
      {'cmd': 'restore_terms', 'id': '111', 'keys': ['a'], 'app': 'ghostty', 'req': anything},
    );
    expect(s.newTermSource('111'), 'term:pty:a');
    await tester.runAsync(() => s.openText('111', from: s.newTermSource('111')));
    expect(
      t.sent.firstWhere((m) => m['cmd'] == 'open_term'),
      {'cmd': 'open_term', 'id': '111', 'app': 'ghostty', 'from': 'term:pty:a', 'req': anything},
    );
  });
}
