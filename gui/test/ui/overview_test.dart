import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/term/term_session_port.dart';
import 'package:rapp/embed/traffic_label.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/device_os.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/os_mark.dart';
import 'package:rapp/ui/workspace_store.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/fullscreen.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/state/state_sync.dart';
import 'dart:async';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/terms_entry.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late FakeSessionPort port;
  late MainState s;
  late Directory tmp;
  var hosts = <Map<String, String>>[];
  var sid = 0;
  var offline = <String>{};
  String? hubVersion;
  var versions = <String, String>{};
  var appsOf = <String, List<Map<String, String>>>{};
  var capsOf = <String, Map<String, Object>>{};

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('overview_test');
    hosts = [
      {'id': 'm1', 'name': 'mini'},
    ];
    sid = 0;
    offline = {};
    hubVersion = null;
    versions = {};
    appsOf = {};
    capsOf = {};
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Builds the state, opens [apps] (`id/app`) in order and shows the overview.
  Future<void> boot(WidgetTester tester,
      {List<String> apps = const [],
      bool embed = true,
      TermSessionPort? termPort,
      String? stateRules,
      DeviceOs? localOs,
      StateSync? stateSync,
      ServiceMonitor? monitor}) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    t = FakeTransport();
    port = FakeSessionPort();
    t.onSend = (m) {
      if (m['cmd'] == 'hosts') {
        t.emit({'event': 'hosts', 'req': m['req'], 'hosts': hosts, 'version': ?hubVersion});
      } else if (m['cmd'] == 'apps') {
        t.emit(offline.contains(m['id'])
            ? {'event': 'error', 'req': m['req'], 'error': 'connect timed out'}
            : {'event': 'apps', 'req': m['req'], 'id': m['id'], 'path': 'lan', 'apps': appsOf[m['id']] ?? [], 'capabilities': ?capsOf[m['id']], 'version': ?versions[m['id']]});
      } else if (m['cmd'] == 'open') {
        t.emit({
          'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan',
          if (m['embed'] == true) ...{'port': 5000 + sid, 'token': 'tk'},
          'req': m['req'],
        });
      }
    };
    final epoch = DateTime(2026, 11, 13, 12);
    s = MainState(
      hub: HubClient(t),
      data: DataDir(tmp.path),
      prefs: UiPrefs(),
      port: embed ? port : null,
      termPort: termPort,
      clock: () => epoch,
      builtinStateRules: stateRules,
      localOs: localOs,
      stateSync: stateSync,
      monitor: monitor,
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await flush();
      }
      for (final a in apps) {
        final p = a.split('/');
        s.openOrSwitch(p[0], p[1], p[1]);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      }
    });
  }

  Future<void> show(WidgetTester tester) async {
    s.toggleOverview();
    await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s))));
    await tester.pump();
  }

  void frame(int sidN, {int bytes = 0}) {
    port.emit(ReadyEvent(sidN, 'x'));
    port.emit(TrafficEvent(sidN, bytes, 1));
  }

  Finder inside(String key, Finder f) => find.descendant(of: find.byKey(Key(key)), matching: f);

  Text numberOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)).first);

  BoxDecoration deco(WidgetTester tester, String key) =>
      tester.widget<Container>(find.byKey(Key(key))).decoration! as BoxDecoration;

  RappTokens tokens(WidgetTester tester) => RappTokens.of(tester.element(find.byType(Overview)));

  testWidgets('two sessions, one disconnected: counts and blocks', (tester) async {
    await boot(tester, apps: ['m1/a', 'm1/b']);
    frame(1, bytes: 48000);
    port.emit(const DisconnectedEvent(2, 'user'));
    await show(tester);
    expect(numberOf(tester, 'count-active').data, '1');
    expect(numberOf(tester, 'count-disconnected').data, '1');
    expect(find.byKey(const Key('block-m1/a')), findsOneWidget);
    expect(find.byKey(const Key('block-m1/b')), findsOneWidget);
    expect(inside('block-m1/a', find.text('48.0 KB/s')), findsOneWidget);
    final reason = s.entries.firstWhere((e) => e.app == 'b').reason!;
    expect(inside('block-m1/b', find.text('已断开：$reason')), findsOneWidget);
  });

  testWidgets('an inferred app state shows the word and 推断', (tester) async {
    await boot(tester,
        apps: ['m1/a'], stateRules: '{"version":1,"packs":[{"format":"1.0","id":"t","rev":1,"ids":["a"]}]}');
    frame(1);
    port.emit(const AppStateEvent(1, '{"state":"working","health":"ok","sure":false,"pack":"t","rev":1}'));
    await show(tester);
    expect(inside('block-m1/a', find.textContaining('在干活')), findsOneWidget);
    expect(inside('block-m1/a', find.textContaining('推断')), findsOneWidget);
  });

  testWidgets('an opened terminal shows its program status in place of the traffic, every state', (tester) async {
    final term = FakeTermSessionPort();
    await boot(tester, apps: ['m1/term:pty:a'], termPort: term);
    term.play(const ReadyEvent(1, 'x'));
    term.play(const TrafficEvent(1, 48000, 1));
    Future<void> report(Map<String, Object?> ps) async {
      await tester.runAsync(() async {
        t.emit({
          'event': 'terms',
          'id': 'm1',
          'terms': [
            {'id': 'term:pty:a', 'name': 'a', 'command': 'claude', 'activity': 1, 'dead': false, 'ps': ps},
          ],
          'hosts': [],
        });
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
    }

    await show(tester);
    expect(inside('block-m1/term:pty:a', find.text('48.0 KB/s')), findsOneWidget);
    for (final (ps, word) in [
      ({'state': 'working', 'progress': 42}, '在干活 · 42%'),
      ({'state': 'blocked', 'kind': 'permission', 'msg': 'approve Bash: ls'}, '等确认 · approve Bash: ls'),
      ({'state': 'error', 'msg': 'API Error: 400'}, '出错 · API Error: 400'),
      ({'state': 'done'}, '完成'),
      ({'state': 'idle'}, '空闲'),
    ]) {
      await report({...ps, 'seq': 1});
      expect(inside('block-m1/term:pty:a', find.text(word)), findsOneWidget, reason: word);
      expect(inside('block-m1/term:pty:a', find.text('48.0 KB/s')), findsNothing, reason: word);
    }
    expect(find.bySemanticsLabel(RegExp('^CLI · a，空闲')), findsOneWidget);
  });

  testWidgets('favourites with no session are listed under 常用 and open on a tap', (tester) async {
    await boot(tester, apps: ['m1/a']);
    s.toggleFavorite('m1', 'a', 'a'); // open already: not listed again
    s.toggleFavorite('m1', 'com.apple.Notes', 'Notes');
    await show(tester);
    expect(find.text('常用'), findsOneWidget);
    expect(find.byKey(const Key('ov-favorite-m1/a')), findsNothing);
    expect(find.byKey(const Key('ov-favorite-m1/com.apple.Notes')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ov-favorite-m1/com.apple.Notes')));
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    expect(s.entries.map((e) => e.app), contains('com.apple.Notes'));
  });

  testWidgets('常用 · 终端 says 新建 and opens a new terminal each tap', (tester) async {
    await boot(tester);
    TermList list() => TermList('m1',
        terms: [TermRow('term:pty:a', 'a', 'zsh', null, 1, 0, 1, true, false)], hosts: [TermHost(null, launchers: const ['Terminal'])]);
    s.prefs.termOpen['m1'] = 'text';
    s.hub!.termLists['m1'] = list();
    final inner = t.onSend!;
    var n = 0;
    t.onSend = (m) {
      if (m['cmd'] == 'open_term') {
        t.emit({'event': 'term_created', 'req': m['req'], 'id': m['id'], 'term': 'term:pty:n${++n}'});
      } else if (m['cmd'] == 'terms') {
        t.emit({'event': 'terms', 'req': m['req'], 'id': m['id'], 'terms': [], 'hosts': [{'host': null, 'launchers': ['Terminal']}]});
      } else {
        inner(m);
      }
    };
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    const key = Key('ov-favorite-m1/terms:');
    expect(find.descendant(of: find.byKey(key), matching: find.text('新建')), findsOneWidget);
    expect(find.bySemanticsLabel('常用 终端，点按新建'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      if (!s.overview) s.toggleOverview();
      await tester.pump();
      await tester.tap(find.byKey(key));
      await tester.runAsync(() async {
        for (var j = 0; j < 6; j++) {
          await flush();
        }
      });
      await tester.pump();
    }
    expect(t.sent.where((m) => m['cmd'] == 'open_term').length, 2);
  });

  testWidgets('常用 · 终端 says 恢复 when only terminals saved before boot are left, and opens the list', (tester) async {
    await boot(tester);
    s.prefs.termOpen['m1'] = 'text';
    s.hub!.termLists['m1'] = TermList('m1', hosts: [
      TermHost(null, launchers: const ['Terminal'], saved: const [TermSaved('a', 'rapp', prog: 'claude', saved: 1, boot: true)]),
    ]);
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    const key = Key('ov-favorite-m1/terms:');
    expect(find.descendant(of: find.byKey(key), matching: find.text('恢复')), findsOneWidget);
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    expect(find.textContaining('恢复上次的终端'), findsOneWidget);
    expect(t.sent.where((m) => m['cmd'] == 'open_term'), isEmpty);
  });

  testWidgets('常用 · 终端 新建 tapped again while the host is still opening sends nothing and says 请稍候', (tester) async {
    await boot(tester);
    s.prefs.termOpen['m1'] = 'text';
    s.hub!.termLists['m1'] = TermList('m1',
        terms: [TermRow('term:pty:a', 'a', 'zsh', null, 1, 0, 1, true, false)], hosts: [TermHost(null, launchers: const ['Terminal'])]);
    final inner = t.onSend!;
    final gate = Completer<void>();
    var n = 0;
    t.onSend = (m) {
      if (m['cmd'] == 'open_term') {
        final reply = {'event': 'term_created', 'req': m['req'], 'id': m['id'], 'term': 'term:pty:n${++n}'};
        if (n == 1) {
          gate.future.then((_) => t.emit(reply));
        } else {
          t.emit(reply);
        }
      } else if (m['cmd'] == 'terms') {
        t.emit({'event': 'terms', 'req': m['req'], 'id': m['id'], 'terms': [], 'hosts': [{'host': null, 'launchers': ['Terminal']}]});
      } else {
        inner(m);
      }
    };
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    const key = Key('ov-favorite-m1/terms:');
    Future<void> tap() async {
      if (!s.overview) s.toggleOverview();
      await tester.pump();
      await tester.tap(find.byKey(key));
      await tester.runAsync(() async {
        for (var j = 0; j < 6; j++) {
          await flush();
        }
      });
      await tester.pump();
    }

    await tap();
    await tap();
    await tap();
    expect(t.sent.where((m) => m['cmd'] == 'open_term').length, 1);
    expect(s.hint, '正在新建终端，请稍候');
    // new_terms_from_overview_shows_wait: the one being made is on the wait card.
    await tester.pump(const Duration(milliseconds: 400));
    expect(s.waits.shown.single.what, '正在新建终端…');
    await tester.runAsync(() async {
      gate.complete();
      for (var j = 0; j < 6; j++) {
        await flush();
      }
    });
    await tester.pump();
    await tap();
    expect(t.sent.where((m) => m['cmd'] == 'open_term').length, 2);
  });

  testWidgets('a cut-off Terminal script on the host reads as a permission question on that Mac', (tester) async {
    await boot(tester);
    expect(MainState.newTermWords(HubException('Terminal did not answer: on that Mac, allow rApp to control Terminal and System Events')),
        contains('允许 rApp 控制“终端”'));
    expect(MainState.newTermWords(HubException('device offline')), 'device offline');
    expect(MainState.newTermWords(TimeoutException('x')), '新建终端没有回应，请稍后再试');
  });

  const asking = 'macOS is asking on that Mac whether rApp may control Terminal: answer it there, then open again';

  testWidgets('a permission prompt on the host is said at once', (tester) async {
    await boot(tester);
    expect(MainState.newTermWords(HubException(asking)), contains('授权框'));
    expect(MainState.newTermWords(HubException(asking)), contains('点「允许」'));
  });

  Future<void> newTermAsked(WidgetTester tester, {Future<void> Function()? go}) async {
    s.prefs.termOpen['m1'] = 'text';
    s.hub!.termLists['m1'] = TermList('m1', hosts: [TermHost(null, launchers: const ['Terminal'])]);
    final inner = t.onSend!;
    t.onSend = (m) {
      if (m['cmd'] == 'open_term') {
        t.emit({'event': 'error', 'req': m['req'], 'error': asking});
      } else if (m['cmd'] == 'terms') {
        t.emit({'event': 'terms', 'req': m['req'], 'id': m['id'], 'terms': [], 'hosts': [{'host': null, 'launchers': ['Terminal']}]});
      } else {
        inner(m);
      }
    };
    await tester.runAsync(() async {
      final done = go?.call() ?? s.newTermFromRestore('m1');
      for (var j = 0; j < 6; j++) {
        await flush();
      }
      await done;
      for (var j = 0; j < 6; j++) {
        await flush();
      }
    });
    await tester.pump();
  }

  testWidgets('a permission prompt on the host brings up its desktop to answer it', (tester) async {
    await boot(tester);
    await newTermAsked(tester);
    expect(s.hint, contains('授权框'));
    expect(s.hint, endsWith('已切到它的桌面'));
    expect(t.sent.where((m) => m['cmd'] == 'open').map((m) => m['app']), ['desktop:']);
  });

  testWidgets('new_term_from_consent_shows_desktop: ⌘T into a permission prompt says so on the card and shows the desktop',
      (tester) async {
    await boot(tester);
    await newTermAsked(tester, go: () => s.newTermFrom('m1', 'last'));
    expect(s.waits.outcome!.asks, isTrue);
    expect(s.waits.outcome!.text, startsWith('被控 Mac 上弹出了授权框'));
    expect(s.hint, contains('授权框'));
    expect(s.hint, endsWith('已切到它的桌面'));
    expect(t.sent.where((m) => m['cmd'] == 'open').map((m) => m['app']), ['desktop:']);
  });

  testWidgets('a permission prompt while the host desktop is on the stage stays on that screen', (tester) async {
    await boot(tester);
    await tester.runAsync(() async {
      await s.openOrSwitch('m1', 'desktop:', '桌面');
      for (var j = 0; j < 6; j++) {
        await flush();
      }
    });
    expect(s.currentKey, 'm1/desktop:');
    s.toggleOverview();
    await newTermAsked(tester);
    expect(s.hint, endsWith('不在这块屏上就换一块屏看看'));
    expect(t.sent.where((m) => m['cmd'] == 'open'), hasLength(1));
    expect(s.currentKey, 'm1/desktop:');
    expect(s.overview, isFalse);
  });

  testWidgets('a permission prompt on a host without a desktop is only said', (tester) async {
    capsOf['m1'] = {'graphical': false};
    await boot(tester);
    await newTermAsked(tester);
    expect(s.hint, contains('授权框'));
    expect(s.hint, isNot(contains('桌面')));
    expect(t.sent.where((m) => m['cmd'] == 'open'), isEmpty);
  });

  testWidgets('常用 · 终端 first says 打开 and reopens the running terminals, then says 新建', (tester) async {
    final term = FakeTermSessionPort();
    await boot(tester, termPort: term);
    s.prefs.termOpen['m1'] = 'text';
    s.hub!.termLists['m1'] = TermList('m1',
        terms: [
          TermRow('term:pty:a', 'a', 'zsh', null, 1, 0, 1, false, false),
          TermRow('term:pty:b', 'b', 'zsh', null, 1, 0, 9, false, false),
          TermRow('term:pty:c', 'c', 'zsh', null, 1, 0, 5, true, false),
        ],
        hosts: [TermHost(null, launchers: const ['Terminal'])]);
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    const key = Key('ov-favorite-m1/terms:');
    expect(find.descendant(of: find.byKey(key), matching: find.text('打开')), findsOneWidget);
    await tester.tap(find.byKey(key));
    await tester.runAsync(() async {
      for (var j = 0; j < 8; j++) {
        await flush();
      }
    });
    await tester.pump();
    expect(s.entries.map((e) => e.app).toSet(), {'term:pty:a', 'term:pty:b'});
    expect(s.currentKey, 'm1/term:pty:b');
    expect(t.sent.where((m) => m['cmd'] == 'open_term'), isEmpty);
    if (!s.overview) s.toggleOverview();
    await tester.pump();
    expect(find.descendant(of: find.byKey(key), matching: find.text('新建')), findsOneWidget);
  });

  testWidgets('常用 · 终端 tapped before the terminal list arrives waits for it, not the pixel Terminal', (tester) async {
    final term = FakeTermSessionPort();
    await boot(tester, termPort: term);
    s.prefs.termOpen['m1'] = 'text';
    s.hub!.termLists.remove('m1');
    final inner = t.onSend!;
    t.onSend = (m) {
      if (m['cmd'] == 'terms') {
        t.emit({
          'event': 'terms', 'req': m['req'], 'id': m['id'],
          'terms': [
            {'id': 'term:pty:a', 'name': 'a', 'command': 'zsh', 'activity': 1, 'dead': false},
          ],
          'hosts': [{'host': null, 'launchers': ['Terminal']}],
        });
      } else {
        inner(m);
      }
    };
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    await tester.tap(find.byKey(const Key('ov-favorite-m1/terms:')));
    await tester.runAsync(() async {
      for (var j = 0; j < 8; j++) {
        await flush();
      }
    });
    await tester.pump();
    expect(s.entries.map((e) => e.app), ['term:pty:a']);
  });

  testWidgets('常用 · 终端 says 新建 when every running terminal is already open', (tester) async {
    final term = FakeTermSessionPort();
    await boot(tester, apps: ['m1/term:pty:a'], termPort: term);
    s.prefs.termOpen['m1'] = 'text';
    s.hub!.termLists['m1'] = TermList('m1',
        terms: [TermRow('term:pty:a', 'a', 'zsh', null, 1, 0, 1, false, false)], hosts: [TermHost(null, launchers: const ['Terminal'])]);
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    expect(find.descendant(of: find.byKey(const Key('ov-favorite-m1/terms:')), matching: find.text('新建')), findsOneWidget);
  });

  testWidgets('常用 · 终端 says 打开 in pixels mode', (tester) async {
    await boot(tester);
    s.prefs.termOpen['m1'] = 'pixels';
    s.hub!.termLists['m1'] = TermList('m1', hosts: [TermHost(null, launchers: const ['Terminal'])]);
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    expect(find.descendant(of: find.byKey(const Key('ov-favorite-m1/terms:')), matching: find.text('打开')), findsOneWidget);
  });

  testWidgets('zero counts are muted', (tester) async {
    await boot(tester, apps: ['m1/a']);
    frame(1, bytes: 1000);
    await show(tester);
    expect(numberOf(tester, 'count-idle').style!.color, tokens(tester).muted);
    expect(numberOf(tester, 'count-active').style!.color, tokens(tester).text);
  });

  testWidgets('a nonzero disconnected count is accent with backdrop', (tester) async {
    await boot(tester, apps: ['m1/a', 'm1/b']);
    port.emit(const DisconnectedEvent(2, 'user'));
    await show(tester);
    final tk = tokens(tester);
    expect(deco(tester, 'frame-count-disconnected').border!.top.color, tk.accent);
    expect(
      inside('count-disconnected', find.byType(DecoratedBox))
          .evaluate()
          .any((e) => (e.widget as DecoratedBox).decoration is! BoxDecoration),
      isTrue,
    );
    expect(deco(tester, 'frame-count-waiting').border!.top.color, tk.line);
    expect(deco(tester, 'frame-count-active').border!.top.color, tk.line);
  });

  testWidgets('the current block is outlined in text colour, not accent', (tester) async {
    await boot(tester, apps: ['m1/a', 'm1/b']);
    frame(1);
    frame(2);
    s.select('m1/b');
    await show(tester);
    final tk = tokens(tester);
    final cur = deco(tester, 'frame-block-m1/b').border!.top;
    expect((cur.color, cur.width), (tk.text, 2.0));
    final other = deco(tester, 'frame-block-m1/a').border!.top;
    expect((other.color, other.width), (tk.line, 1.0));
  });

  testWidgets('one click on a block enters it', (tester) async {
    await boot(tester, apps: ['m1/a', 'm1/b']);
    frame(1);
    frame(2);
    s.select('m1/a');
    await show(tester);
    expect(s.overview, true);
    await tester.tap(find.byKey(const Key('block-m1/b')));
    await tester.pump();
    expect(s.overview, false);
    expect(s.currentKey, 'm1/b');
  });

  testWidgets('windows count shows from two', (tester) async {
    await boot(tester, apps: ['m1/a']);
    frame(1);
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
    port.emit(WindowsEvent(1, [rw(1)]));
    await show(tester);
    expect(find.textContaining('个窗口'), findsNothing);
    port.emit(WindowsEvent(1, [rw(1), rw(2)]));
    await tester.pump();
    expect(inside('block-m1/a', find.text('2 个窗口')), findsOneWidget);
  });

  testWidgets('columns follow the device panel order; offline is grey', (tester) async {
    hosts = [
      {'id': 'm1', 'name': 'mini'},
      {'id': 'm2', 'name': 'air'},
    ];
    offline = {'m2'};
    await boot(tester, apps: ['m1/a']);
    await show(tester);
    double x(String k) => tester.getTopLeft(find.byKey(Key(k))).dx;
    expect(x('column-local'), lessThan(x('column-m1')));
    expect(x('column-m1'), lessThan(x('column-m2')));
    final title = tester.widget<Text>(inside('column-m2', find.text('air')));
    expect(title.style!.color, tokens(tester).muted);
    expect(inside('column-m2', find.text('离线')), findsOneWidget);
  });

  testWidgets('each column shows its system mark left of the lamp, offline too', (tester) async {
    hosts = [
      {'id': 'm1', 'name': 'A', 'os': 'windows'},
    ];
    offline = {'m1'};
    await boot(tester, localOs: DeviceOs.macos);
    await show(tester);
    OsMark mark(String k) => tester.widget<OsMark>(find.byKey(Key(k)));
    expect(mark('os-mark-local').os, DeviceOs.macos);
    expect(mark('os-mark-m1').os, DeviceOs.windows);
    final lamp = find.descendant(of: find.byKey(const Key('column-m1')), matching: find.byType(StatusLamp));
    expect(tester.getTopLeft(find.byKey(const Key('os-mark-m1'))).dx, lessThan(tester.getTopLeft(lamp.first).dx));
    expect(find.descendant(of: find.byKey(const Key('column-m1')), matching: find.byKey(const Key('os-mark-m1'))),
        findsOneWidget);
  });

  testWidgets('each column shows its version at the bottom in muted text; none when unknown', (tester) async {
    hosts = [
      {'id': 'm1', 'name': 'mini'},
      {'id': 'm2', 'name': 'air'},
    ];
    hubVersion = '0.14.7';
    versions = {'m1': '0.14.8'};
    await boot(tester, apps: ['m1/a']);
    await show(tester);
    // No local service here: 本机 starts folded, so open it to see its version.
    await tester.tap(find.byKey(const Key('column-local-folded')));
    await tester.pump();
    final m1 = tester.widget<Text>(find.byKey(const Key('version-m1')));
    expect(m1.data, '0.14.8');
    expect(m1.style!.color, tokens(tester).muted);
    expect(tester.widget<Text>(find.byKey(const Key('version-local'))).data, '0.14.7');
    expect(find.byKey(const Key('version-m2')), findsNothing);
    // At the bottom: below the column's session block.
    expect(tester.getTopLeft(find.byKey(const Key('version-m1'))).dy,
        greaterThan(tester.getBottomLeft(inside('column-m1', find.byType(Text)).first).dy));
  });

  // ---- 打开应用 ----
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await flush();
      }
    });
    await tester.pump();
  }

  Future<void> openMenu(WidgetTester tester, [String id = 'm1']) async {
    await tester.tap(find.byKey(Key('open-apps-$id')));
    await tester.pump();
    await settle(tester);
  }

  const menu = Key('open-apps-menu');

  void twoApps() => appsOf = {
        'm1': [
          {'app': 'desktop:', 'name': '桌面'},
          {'app': 'com.x.Notes', 'name': 'Notes'},
          {'app': 'com.x.Safari', 'name': 'Safari'},
        ],
      };

  testWidgets('打开应用 sits right of the version on remote columns only; no more 打开 app', (tester) async {
    hubVersion = '0.14.7';
    versions = {'m1': '0.14.8'};
    await boot(tester, apps: []);
    await show(tester);
    final link = find.byKey(const Key('open-apps-m1'));
    expect(link, findsOneWidget);
    expect(find.byKey(const Key('open-apps-local')), findsNothing);
    expect(find.byKey(const Key('open-app-m1')), findsNothing);
    expect(find.text('打开 app'), findsNothing);
    final v = tester.getCenter(find.byKey(const Key('version-m1')));
    expect((tester.getCenter(link).dy - v.dy).abs(), lessThan(4));
    expect(tester.getTopRight(link).dx, moreOrLessEquals(tester.getTopRight(find.byKey(const Key('column-m1'))).dx, epsilon: 1));
    expect(tester.getSize(link).height, greaterThanOrEqualTo(48));
  });

  testWidgets('an offline device: 打开应用 does not open', (tester) async {
    offline = {'m1'};
    await boot(tester, apps: []);
    await show(tester);
    await tester.tap(find.byKey(const Key('open-apps-m1')), warnIfMissed: false);
    await tester.pump();
    expect(find.byKey(menu), findsNothing);
  });

  testWidgets('the menu groups the apps; a tap opens one and closes the menu', (tester) async {
    twoApps();
    await boot(tester, apps: []);
    await show(tester);
    await openMenu(tester);
    expect(find.byKey(menu), findsOneWidget);
    expect(find.text('屏幕'), findsOneWidget);
    expect(find.text('应用（2）'), findsOneWidget);
    expect(find.byKey(const Key('open-apps-star-desktop:')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-apps-row-com.x.Notes')));
    await settle(tester);
    expect(s.entries.map((e) => e.app), contains('com.x.Notes'));
    expect(find.byKey(menu), findsNothing);
  });

  testWidgets('an open app reads 已打开 and a tap switches to it', (tester) async {
    twoApps();
    await boot(tester, apps: ['m1/com.x.Safari']);
    await show(tester);
    await openMenu(tester);
    expect(find.descendant(of: find.byKey(const Key('open-apps-row-com.x.Safari')), matching: find.text('连接中')), findsOneWidget);
    frame(1);
    await settle(tester);
    expect(find.descendant(of: find.byKey(const Key('open-apps-row-com.x.Safari')), matching: find.text('已打开')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-apps-row-com.x.Safari')));
    await settle(tester);
    expect(s.currentKey, 'm1/com.x.Safari');
    expect(s.entries.where((e) => e.app == 'com.x.Safari'), hasLength(1));
  });

  testWidgets('the star toggles 常用 and keeps the menu open', (tester) async {
    twoApps();
    await boot(tester, apps: []);
    await show(tester);
    await openMenu(tester);
    await tester.tap(find.byKey(const Key('open-apps-star-com.x.Notes')));
    await tester.pump();
    expect(s.isFavorite('m1', 'com.x.Notes'), isTrue);
    expect(find.byKey(menu), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-apps-star-com.x.Notes')));
    await tester.pump();
    expect(s.isFavorite('m1', 'com.x.Notes'), isFalse);
  });

  testWidgets('typing filters; Return opens the first match; no match does nothing', (tester) async {
    twoApps();
    await boot(tester, apps: []);
    await show(tester);
    await openMenu(tester);
    await tester.enterText(find.byKey(const Key('open-apps-filter')), 'zzz');
    await tester.pump();
    expect(find.text('没有匹配的应用'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.byKey(menu), findsOneWidget);
    await tester.enterText(find.byKey(const Key('open-apps-filter')), 'saf');
    await tester.pump();
    expect(find.byKey(const Key('open-apps-row-com.x.Notes')), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(s.entries.map((e) => e.app), contains('com.x.Safari'));
    expect(find.byKey(menu), findsNothing);
  });

  testWidgets('arrow keys move the pick; Escape closes', (tester) async {
    twoApps();
    await boot(tester, apps: []);
    await show(tester);
    await openMenu(tester);
    await tester.showKeyboard(find.byKey(const Key('open-apps-filter')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(s.entries.map((e) => e.app), ['com.x.Notes']);
    await openMenu(tester);
    expect(find.byKey(menu), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(menu), findsNothing);
  });

  testWidgets('设备详情 goes to the device panel; a bundle id opens that app', (tester) async {
    twoApps();
    await boot(tester, apps: []);
    await show(tester);
    await openMenu(tester);
    await tester.enterText(find.byKey(const Key('open-apps-bundle')), 'com.y.Pages');
    await tester.tap(find.byKey(const Key('open-apps-bundle-open')));
    await settle(tester);
    expect(s.entries.map((e) => e.app), contains('com.y.Pages'));
    expect(find.byKey(menu), findsNothing);
    await openMenu(tester);
    await tester.tap(find.byKey(const Key('open-apps-details')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(s.panel, PanelTab.devices);
    expect(s.deviceTab, 'm1');
    expect(find.byKey(menu), findsNothing);
  });

  testWidgets('apps not read yet: 正在读取…', (tester) async {
    await boot(tester, apps: []);
    s.probes.remove('m1');
    t.onSend = (m) {}; // the probe never answers
    await show(tester);
    await openMenu(tester);
    expect(find.text('正在读取…'), findsOneWidget);
  });

  testWidgets('near the bottom the menu opens upward and stays on screen', (tester) async {
    twoApps();
    await boot(tester, apps: ['m1/com.x.Safari']); // a block above pushes the link down
    tester.view.physicalSize = const Size(1194, 320);
    addTearDown(tester.view.resetPhysicalSize);
    s.toggleOverview();
    await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 320, child: Overview(state: s))));
    await tester.pump();
    await openMenu(tester);
    final r = tester.getRect(find.byKey(menu));
    final link = tester.getRect(find.byKey(const Key('open-apps-m1')));
    expect(link.bottom, greaterThan(320 - 200), reason: 'the link is near the bottom');
    expect(r.bottom, lessThanOrEqualTo(link.top + 1));
    expect(r.top, greaterThanOrEqualTo(0));
    expect(r.right, moreOrLessEquals(link.right, epsilon: 1));
    expect(r.width, 290);
  });

  testWidgets('the menu fills in place when the apps arrive; a pick made before keeps its app', (tester) async {
    twoApps();
    await boot(tester, apps: []);
    s.hub!.termLists['m1'] = const TermList('m1');
    s.probes.remove('m1');
    final send = t.onSend!;
    Map<String, dynamic>? held;
    t.onSend = (m) => m['cmd'] == 'apps' ? held = m : send(m);
    await show(tester);
    await openMenu(tester);
    expect(find.text('正在读取…'), findsOneWidget);
    expect(find.byKey(const Key('open-apps-row-terms:')), findsOneWidget);
    await tester.showKeyboard(find.byKey(const Key('open-apps-filter')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // picks 终端, the only row
    t.onSend = send;
    send(held!);
    await settle(tester);
    expect(find.text('正在读取…'), findsNothing);
    expect(find.byKey(const Key('open-apps-row-com.x.Notes')), findsOneWidget);
    // 屏幕 now sits above 终端: Return still opens 终端, not 桌面.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.byKey(menu), findsNothing);
    expect(s.entries.map((e) => e.app), isNot(contains('desktop:')));
  });

  testWidgets('a text-only device: the 终端 group plus why there are no apps; no bundle field', (tester) async {
    capsOf = {'m1': {'graphical': false}};
    await boot(tester, apps: []);
    s.hub!.termLists['m1'] = const TermList('m1');
    await show(tester);
    await openMenu(tester);
    expect(find.byKey(const Key('open-apps-row-terms:')), findsOneWidget);
    expect(find.text('屏幕'), findsNothing);
    expect(find.text('这台设备支持文本终端和端口分享，暂不提供应用画面'), findsOneWidget);
    expect(find.byKey(const Key('open-apps-bundle')), findsNothing);
  });

  testWidgets('the device goes offline while the menu is open: the reason shows, nothing opens', (tester) async {
    twoApps();
    await boot(tester, apps: []);
    await show(tester);
    await openMenu(tester);
    offline = {'m1'};
    s.probe('m1');
    await settle(tester);
    expect(find.byKey(menu), findsOneWidget);
    expect(find.textContaining('连接'), findsWidgets);
    await tester.tap(find.byKey(const Key('open-apps-row-com.x.Notes')));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(s.entries, isEmpty);
    expect(find.byKey(menu), findsOneWidget);
  });

  testWidgets('arrow keys keep the pick in view across group titles', (tester) async {
    appsOf = {
      'm1': [
        {'app': 'desktop:', 'name': '桌面'},
        for (var i = 0; i < 20; i++) {'app': 'com.x.A$i', 'name': 'App $i'},
      ],
    };
    await boot(tester, apps: []);
    s.hub!.termLists['m1'] = const TermList('m1');
    await show(tester);
    await openMenu(tester);
    await tester.showKeyboard(find.byKey(const Key('open-apps-filter')));
    for (var i = 0; i < 14; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    final view = tester.getRect(find.descendant(of: find.byKey(menu), matching: find.byType(SingleChildScrollView)));
    final row = tester.getRect(find.byKey(const Key('open-apps-row-com.x.A12')));
    expect(row.top, greaterThanOrEqualTo(view.top - 0.5));
    expect(row.bottom, lessThanOrEqualTo(view.bottom + 0.5));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(s.entries.map((e) => e.app), ['com.x.A12']);
  });

  testWidgets('the link reads 打开应用，<name> and has a tap action', (tester) async {
    final handle = tester.ensureSemantics();
    twoApps();
    await boot(tester, apps: []);
    await show(tester);
    expect(tester.getSemantics(find.byKey(const Key('open-apps-m1'))),
        matchesSemantics(label: '打开应用，mini', isButton: true, hasEnabledState: true, isEnabled: true, hasTapAction: true));
    handle.dispose();
  });

  testWidgets('Linux: 打开应用 menu keeps desktop row height, hover pick, star + Esc and narrow bounds', (tester) async {
    twoApps();
    await boot(tester, apps: []);
    tester.view.physicalSize = const Size(340, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    s.toggleOverview();
    await tester.pumpWidget(wrap(SizedBox(width: 340, height: 800, child: Overview(state: s))));
    await tester.pump();
    await openMenu(tester);
    final menuRect = tester.getRect(find.byKey(menu));
    expect(menuRect.left, greaterThanOrEqualTo(8));
    expect(menuRect.right, lessThanOrEqualTo(332));
    expect(tester.getSize(find.byKey(const Key('open-apps-row-com.x.Notes'))).height, 32);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.descendant(of: find.byKey(const Key('open-apps-row-com.x.Safari')), matching: find.text('Safari'))));
    await tester.pump();
    expect(
      find.descendant(of: find.byKey(const Key('open-apps-row-com.x.Safari')), matching: find.text('打开')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('open-apps-star-com.x.Safari')));
    await tester.pump();
    expect(s.isFavorite('m1', 'com.x.Safari'), isTrue);
    expect(find.byKey(menu), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(menu), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux desktop-only host: shows 屏幕 and 终端 without the bundle id field', (tester) async {
    capsOf = {
      'm1': {'graphical': true, 'desktop': true, 'applications': false, 'terminal': true, 'ports': true},
    };
    appsOf = {
      'm1': [
        {'app': 'desktop:', 'name': '桌面'},
      ],
    };
    await boot(tester, apps: []);
    s.hub!.termLists['m1'] = const TermList('m1');
    await show(tester);
    await openMenu(tester);
    expect(find.text('屏幕'), findsOneWidget);
    expect(find.byKey(const Key('open-apps-row-desktop:')), findsOneWidget);
    expect(find.text('终端'), findsNWidgets(2));
    expect(find.byKey(const Key('open-apps-row-terms:')), findsOneWidget);
    expect(find.byKey(const Key('open-apps-bundle')), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux: overview shows program status, duplicate titles and 常用 · 终端 新建 on a Linux host',
      (tester) async {
    capsOf = {
      'm1': {'graphical': true, 'desktop': true, 'applications': false, 'terminal': true, 'ports': true},
    };
    final term = FakeTermSessionPort();
    await boot(tester, apps: ['m1/term:pty:a'], termPort: term);
    term.play(const ReadyEvent(1, 'x'));
    term.play(const TrafficEvent(1, 24000, 1));
    s.prefs.termOpen['m1'] = 'pixels'; // desktop-only Linux host forces text mode
    final inner = t.onSend!;
    var created = 0;
    t.onSend = (m) {
      if (m['cmd'] == 'open_term') {
        t.emit({'event': 'term_created', 'req': m['req'], 'id': m['id'], 'term': 'term:pty:n${++created}'});
      } else if (m['cmd'] == 'terms') {
        t.emit({
          'event': 'terms',
          'req': m['req'],
          'id': m['id'],
          'terms': [
            {
              'id': 'term:pty:a',
              'name': 'zsh',
              'title': '~/git/rapp · 2',
              'command': 'claude',
              'activity': 1,
              'dead': false,
              'ps': {'state': 'blocked', 'kind': 'permission', 'msg': 'approve Bash: ls', 'seq': 2},
            },
          ],
          'hosts': [
            {
              'host': null,
              'launchers': ['ghostty'],
              'shells': [{'name': 'zsh', 'path': '/bin/zsh', 'default': true}],
            },
          ],
        });
      } else {
        inner(m);
      }
    };
    await tester.runAsync(() async {
      t.emit({
        'event': 'terms',
        'id': 'm1',
        'terms': [
          {
            'id': 'term:pty:a',
            'name': 'zsh',
            'title': '~/git/rapp · 2',
            'command': 'claude',
            'activity': 1,
            'dead': false,
            'ps': {'state': 'blocked', 'kind': 'permission', 'msg': 'approve Bash: ls', 'seq': 2},
          },
        ],
        'hosts': [
          {
            'host': null,
            'launchers': ['ghostty'],
            'shells': [{'name': 'zsh', 'path': '/bin/zsh', 'default': true}],
          },
        ],
      });
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    expect(inside('block-m1/term:pty:a', find.text('CLI · ~/git/rapp · 2')), findsOneWidget);
    expect(inside('block-m1/term:pty:a', find.text('等确认 · approve Bash: ls')), findsOneWidget);
    const fav = Key('ov-favorite-m1/terms:');
    expect(find.descendant(of: find.byKey(fav), matching: find.text('新建')), findsOneWidget);
    await tester.tap(find.byKey(fav));
    await settle(tester);
    final opens = t.sent.where((m) => m['cmd'] == 'open_term').toList();
    expect(opens, hasLength(1));
    expect(opens.single['app'], 'ghostty');
    expect(opens.single['shell'], '/bin/zsh');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux desktop-only host: 常用 · 终端 awaits missing terms list even with saved pixels mode and restores',
      (tester) async {
    capsOf = {
      'm1': {'graphical': true, 'desktop': true, 'applications': false, 'terminal': true, 'ports': true},
    };
    final term = FakeTermSessionPort();
    await boot(tester, termPort: term);
    s.prefs.termOpen['m1'] = 'pixels';
    s.hub!.termLists.remove('m1');
    final inner = t.onSend!;
    t.onSend = (m) {
      if (m['cmd'] == 'terms') {
        t.emit({
          'event': 'terms',
          'req': m['req'],
          'id': m['id'],
          'terms': [
            {'id': 'term:pty:a', 'name': 'zsh', 'title': '~/git/rapp', 'command': 'zsh', 'activity': 2, 'dead': false},
            {'id': 'term:pty:b', 'name': 'zsh-2', 'title': '~/git/rapp · 2', 'command': 'claude', 'activity': 9, 'dead': false},
          ],
          'hosts': [
            {
              'host': null,
              'launchers': ['foot'],
              'shells': [{'name': 'bash', 'path': '/bin/bash', 'default': true}],
            },
          ],
        });
      } else {
        inner(m);
      }
    };
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    const fav = Key('ov-favorite-m1/terms:');
    await tester.tap(find.byKey(fav));
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await flush();
      }
    });
    await tester.pump();
    expect(s.entries.map((e) => e.app).toSet(), {'term:pty:a', 'term:pty:b'});
    expect(s.currentKey, 'm1/term:pty:b');
    expect(t.sent.where((m) => m['cmd'] == 'open_term'), isEmpty);
    if (!s.overview) s.toggleOverview();
    await tester.pump();
    expect(find.descendant(of: find.byKey(fav), matching: find.text('新建')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux: terminal block shows fg program title with CLI subtitle and 新建 runs one at a time',
      (tester) async {
    capsOf = {
      'm1': {'graphical': true, 'desktop': true, 'applications': false, 'terminal': true, 'ports': true},
    };
    final term = FakeTermSessionPort();
    await boot(tester, apps: ['m1/term:pty:a'], termPort: term);
    term.play(const ReadyEvent(1, 'x'));
    final inner = t.onSend!;
    int? pendingReq;
    t.onSend = (m) {
      if (m['cmd'] == 'open_term') {
        pendingReq = m['req'] as int?;
      } else {
        inner(m);
      }
    };
    await tester.runAsync(() async {
      t.emit({
        'event': 'terms',
        'id': 'm1',
        'terms': [
          {
            'id': 'term:pty:a',
            'name': 'zsh',
            'title': '~/git/rapp · 2',
            'fg': 'claude',
            'shell': false,
            'command': 'zsh',
            'activity': 1,
            'dead': false,
            'ps': {'state': 'blocked', 'kind': 'permission', 'msg': 'approve Bash: ls', 'seq': 2},
          },
        ],
        'hosts': [
          {
            'host': null,
            'launchers': ['ghostty'],
            'shells': [{'name': 'zsh', 'path': '/bin/zsh', 'default': true}],
          },
        ],
      });
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    s.toggleFavorite('m1', termsEntry, termsEntryName);
    await show(tester);
    expect(inside('block-m1/term:pty:a', find.text('claude · ~/git/rapp · 2')), findsOneWidget);
    expect(inside('block-m1/term:pty:a', find.text('CLI · 等确认 · approve Bash: ls')), findsOneWidget);
    const fav = Key('ov-favorite-m1/terms:');
    await tester.tap(find.byKey(fav));
    await tester.pump();
    await tester.tap(find.byKey(fav));
    await tester.pump();
    expect(t.sent.where((m) => m['cmd'] == 'open_term'), hasLength(1));
    expect(s.hint, '正在新建终端，请稍候');
    t.emit({'event': 'term_created', 'req': pendingReq, 'id': 'm1', 'term': 'term:pty:b'});
    await settle(tester);
    // Past the wait card's timers.
    await tester.pump(const Duration(seconds: 9));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('count taps', (tester) async {
    await boot(tester, apps: ['m1/a']);
    port.emit(const DisconnectedEvent(1, 'user'));
    await show(tester);
    await tester.tap(find.byKey(const Key('count-disconnected')));
    await tester.pump();
    expect(s.corner, Corner.needs);
    s.closeCorner();
    await tester.tap(find.byKey(const Key('count-online')));
    await tester.pump();
    expect(s.panel, PanelTab.devices);
    expect(inside('count-active', find.byType(InkWell)), findsNothing);
    expect(find.ancestor(of: find.byKey(const Key('count-active')), matching: find.byType(InkWell)), findsNothing);
  });

  testWidgets('device online shows online/total with 本机, as many as the wall has columns', (tester) async {
    hosts = [
      {'id': 'm1', 'name': 'mini'},
      {'id': 'm2', 'name': 'air'},
    ];
    offline = {'m2'};
    await boot(tester);
    await show(tester);
    expect(inside('count-online', find.text('2/3')), findsOneWidget);
  });

  testWidgets('device online cell shows the offline lamp when every added device is off, active otherwise', (tester) async {
    offline = {'m1'};
    await boot(tester);
    await show(tester);
    expect(inside('count-online', find.text('1/2')), findsOneWidget);
    expect(tester.widget<StatusLamp>(inside('count-online', find.byType(StatusLamp))).kind, Lamp.offline);
    s.dispose();
    offline = {};
    await boot(tester);
    await show(tester);
    expect(inside('count-online', find.text('2/2')), findsOneWidget);
    expect(tester.widget<StatusLamp>(inside('count-online', find.byType(StatusLamp))).kind, Lamp.active);
  });

  testWidgets('traffic cell uses formatRate and — without embedding', (tester) async {
    await boot(tester, apps: ['m1/a']);
    frame(1, bytes: 48000);
    await show(tester);
    expect(inside('count-traffic', find.text(formatRate(s.totalBytesPerSecond))), findsOneWidget);
    expect(inside('count-traffic', find.byType(LevelBars)), findsOneWidget);
    s.dispose();
    tmp.createSync();
    await boot(tester, embed: false);
    await show(tester);
    expect(inside('count-traffic', find.text('—')), findsOneWidget);
  });

  testWidgets('four columns of four fit without scrolling at 1194x834', (tester) async {
    hosts = [for (var i = 1; i <= 4; i++) {'id': 'm$i', 'name': 'mac$i'}];
    // Every column carries its version line, as on real devices.
    hubVersion = '0.14.7';
    versions = {for (var i = 1; i <= 4; i++) 'm$i': '0.14.7'};
    await boot(tester, apps: [
      for (var i = 1; i <= 4; i++)
        for (var j = 0; j < 4; j++) 'm$i/app$j',
    ]);
    tester.view.physicalSize = const Size(1194, 834);
    await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 834 - 56, child: Overview(state: s))));
    s.toggleOverview();
    await tester.pump();
    expect(s.entries.length, 16);
    // One run of four, and the page around it does not scroll.
    final page = find.ancestor(of: find.byKey(const Key('wall')), matching: find.byType(Scrollable));
    expect(page, findsOneWidget);
    expect(tester.state<ScrollableState>(page).position.maxScrollExtent, 0);
    expect(tester.getTopLeft(find.byKey(const Key('column-m4'))).dy, tester.getTopLeft(find.byKey(const Key('column-m1'))).dy);
    for (final e in s.entries) {
      expect(find.byKey(Key('block-${e.key}')), findsOneWidget);
    }
    for (var i = 1; i <= 4; i++) {
      expect(find.byKey(Key('version-m$i')), findsOneWidget);
    }
  });

  testWidgets('blocks and buttons are at least 48 tall', (tester) async {
    hosts = [
      {'id': 'm1', 'name': 'mini'},
      {'id': 'm2', 'name': 'air'},
    ];
    await boot(tester, apps: ['m1/a']);
    port.emit(const DisconnectedEvent(1, 'user'));
    await show(tester);
    for (final k in ['block-m1/a', 'open-apps-m2', 'count-disconnected', 'count-online']) {
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48), reason: k);
    }
  });

  testWidgets('count lamps are still', (tester) async {
    await boot(tester, apps: ['m1/a']);
    await show(tester);
    final lamps = inside('counts', find.byType(StatusLamp));
    expect(lamps, findsWidgets);
    for (final e in lamps.evaluate()) {
      expect(MediaQuery.disableAnimationsOf(e), isTrue);
    }
  });

  // ---- third layer: projects and resources ----
  Rect rectOf(WidgetTester tester, String key) => tester.getRect(find.byKey(Key(key)));

  testWidgets('a project cell shows its name and one lamp per member', (tester) async {
    await boot(tester, apps: ['m1/a']);
    final p = s.createProject('写周报')!;
    s.addMember(p.id, const AppRef('m1', 'a', 'a'));
    s.addMember(p.id, const AppRef('m1', 'b', 'b'));
    s.addMember(p.id, const AppRef('m1', 'c', 'c'));
    frame(1, bytes: 1000);
    await show(tester);
    final cell = 'ov-project-${p.id}';
    expect(inside(cell, find.text('写周报')), findsOneWidget);
    final lamps = inside(cell, find.byType(StatusLamp));
    expect(lamps, findsNWidgets(3));
    expect(tester.widget<StatusLamp>(lamps.first).kind, s.entryFor('m1/a')!.lamp);
    expect(tester.widget<StatusLamp>(lamps.at(1)).kind, Lamp.notOpened);
  });

  testWidgets('no projects: no project cell and no words about it; the resources cell stays (project spec §5)',
      (tester) async {
    await boot(tester, apps: ['m1/a']);
    await show(tester);
    expect(find.textContaining('还没有项目'), findsNothing);
    expect(find.textContaining('项目'), findsNothing);
    expect(find.byKey(const Key('ov-no-projects')), findsNothing);
    expect(find.byKey(const Key('ov-projects')), findsNothing);
    expect(find.byKey(const Key('ov-resources')), findsOneWidget);
  });

  testWidgets('the resources cell sums clips and transfers and opens the resources tab', (tester) async {
    await boot(tester, apps: ['m1/a']);
    port.emit(const ClipsEvent(1, [ClipRow(3, 's4-secret-title', true), ClipRow(2, 'x2', true), ClipRow(1, 'x1', true)]));
    await tester.runAsync(flush);
    await s.togglePin(s.resources.clips.first);
    port.emit(const TransferProgressEvent(1, 7, true, 'a.log', 42, 100, TransferState.running, null, null));
    await show(tester);
    expect(inside('ov-resources', find.text('剪贴板 3 条，固定 1 条')), findsOneWidget);
    expect(inside('ov-resources', find.text('下载 a.log 42%')), findsOneWidget);
    expect(inside('ov-resources', find.textContaining('s4-secret-title')), findsNothing);
    expect(find.textContaining('s4-secret-title'), findsNothing);
    await tester.tap(find.byKey(const Key('ov-resources')));
    expect(s.panel, PanelTab.resources);
  });

  testWidgets('overview: projects row above the device wall when projects come first', (tester) async {
    await boot(tester, apps: ['m1/a']);
    final p = s.createProject('写周报')!;
    await show(tester);
    expect(rectOf(tester, 'ov-project-${p.id}').top, greaterThan(rectOf(tester, 'wall').top));
    s.setFirst(FirstLayer.project);
    await tester.pump();
    expect(rectOf(tester, 'ov-project-${p.id}').top, lessThan(rectOf(tester, 'wall').top));
  });

  testWidgets('overview: pinned projects come first in the row', (tester) async {
    await boot(tester);
    final a = s.createProject('甲')!;
    final b = s.createProject('乙')!;
    s.togglePinned(b.id);
    await show(tester);
    expect(rectOf(tester, 'ov-project-${b.id}').left, lessThan(rectOf(tester, 'ov-project-${a.id}').left));
  });

  testWidgets('the resources cell stays at the right edge', (tester) async {
    await boot(tester);
    for (var i = 0; i < 12; i++) {
      s.createProject('项目$i');
    }
    await show(tester);
    final right = rectOf(tester, 'overview').right - 12;
    expect(rectOf(tester, 'ov-resources').right, right);
    final first = s.projects.first.id;
    final before = rectOf(tester, 'ov-project-$first').left;
    await tester.drag(find.byKey(Key('ov-project-$first')), const Offset(-100, 0));
    await tester.pump();
    expect(rectOf(tester, 'ov-project-$first').left, lessThan(before));
    expect(rectOf(tester, 'ov-resources').right, right);
  });

  testWidgets('third-row cells are at least 48 tall', (tester) async {
    await boot(tester);
    s.createProject('p');
    await show(tester);
    for (final k in ['ov-project-${s.projects.single.id}', 'ov-resources']) {
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48), reason: k);
    }
    s.projects.clear();
  });

  testWidgets('tapping a project opens the projects tab on it', (tester) async {
    await boot(tester);
    final ids = [for (var i = 0; i < 12; i++) s.createProject('项目$i')!.id];
    s.toggleOverview();
    final fs = _Fs();
    await tester.pumpWidget(wrap(
      MainWindow(
        state: s,
        monitor: ServiceMonitor(readToken: () async => null),
        control: null,
        fullscreen: fs,
      ),
      disableAnimations: true,
    ));
    await tester.pump(const Duration(milliseconds: 100));
    final cell = find.byKey(Key('ov-project-${ids.last}'));
    await tester.scrollUntilVisible(cell, 200, scrollable: find.descendant(of: find.byKey(const Key('ov-projects')), matching: find.byType(Scrollable)));
    await tester.pump();
    await tester.tap(cell);
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(s.panel, PanelTab.projects);
    final top = tester.getTopLeft(find.byKey(Key('project-${ids.last}'))).dy;
    expect(top, inInclusiveRange(56, 834));
    expect(s.focusProject, isNull);
  });

  testWidgets('a 600-wide window wraps the wall and the page scrolls up and down (iPad spec §7.2)', (tester) async {
    hosts = [for (var i = 1; i <= 5; i++) {'id': 'm$i', 'name': 'mac$i'}];
    await boot(tester);
    s.toggleOverview();
    await tester.pumpWidget(wrap(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 600, height: 500, child: Overview(state: s)),
    )));
    await tester.pump();
    expect(tester.takeException(), isNull);
    double dy(String k) => tester.getTopLeft(find.byKey(Key(k))).dy;
    expect(dy('column-m5'), greaterThan(dy('column-m1')));
    for (final k in ['column-local', 'column-m1', 'column-m5']) {
      expect(tester.getRect(find.byKey(Key(k))).right, lessThanOrEqualTo(600), reason: k);
    }
    final page = find.ancestor(of: find.byKey(const Key('wall')), matching: find.byType(Scrollable));
    expect(page, findsOneWidget);
    final pos = tester.state<ScrollableState>(page).position;
    expect(pos.axis, Axis.vertical);
    expect(pos.maxScrollExtent, greaterThan(0));
    final before = dy('column-m1');
    await tester.drag(find.byKey(const Key('wall')), const Offset(0, -200));
    await tester.pump();
    expect(dy('column-m1'), lessThan(before));
  });

  group('local column fold', () {
    testWidgets('no local service: the 本机 column starts folded, 56 wide', (tester) async {
      hubVersion = '0.14.7';
      await boot(tester);
      await show(tester);
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('column-local'))).width, 56);
      expect(inside('column-local', find.text('本机')), findsOneWidget);
      expect(find.byKey(const Key('os-mark-local')), findsOneWidget);
      expect(inside('column-local', find.text('没有打开的 app')), findsNothing);
      expect(find.byKey(const Key('version-local')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap opens it; the fold button closes it again', (tester) async {
      hubVersion = '0.14.7';
      await boot(tester);
      await show(tester);
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('column-local'))).width, 220);
      expect(find.byKey(const Key('version-local')), findsOneWidget);
      await tester.tap(find.byKey(const Key('column-local-fold')));
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
    });

    testWidgets('stays open across rebuilds', (tester) async {
      await boot(tester);
      await show(tester);
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      s.say('x');
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsNothing);
      expect(find.byKey(const Key('column-local-fold')), findsOneWidget);
    });

    testWidgets('stays open after leaving the overview and coming back', (tester) async {
      await boot(tester);
      await show(tester);
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      // Leaving 全景 unmounts the overview (the stage takes its place); coming back mounts a fresh one.
      await tester.pumpWidget(wrap(const SizedBox()));
      await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s))));
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsNothing);
      expect(find.byKey(const Key('column-local-fold')), findsOneWidget);
    });

    testWidgets('the fold button is a touch-sized target', (tester) async {
      await boot(tester);
      await show(tester);
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      final size = tester.getSize(find.byKey(const Key('column-local-fold')));
      expect(size.height, greaterThanOrEqualTo(44));
      expect(size.width, greaterThanOrEqualTo(44));
    });

    Future<_Mon> showPc(WidgetTester tester, [_Mon? given]) async {
      s.toggleOverview();
      final m = given ?? _Mon();
      addTearDown(m.dispose);
      await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s, monitor: m))));
      await tester.pump();
      return m;
    }

    final one = [const ServiceSession(1, 'm1', 'desktop:', 'relay', null)];
    final two = [...one, const ServiceSession(2, 'm1', 'term:', 'relay', null)];

    testWidgets('PC with nobody connected in: 本机 starts folded', (tester) async {
      await boot(tester);
      await showPc(tester);
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('column-local'))).width, 56);
    });

    testWidgets('PC opens 本机 while someone is connected in, folds when they leave', (tester) async {
      await boot(tester);
      final m = await showPc(tester);
      m.set(one);
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('column-local'))).width, 220);
      expect(find.byKey(const Key('column-local-fold')), findsOneWidget);
      m.set(const []);
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
    });

    testWidgets('a manual fold sticks while sessions come and go', (tester) async {
      await boot(tester);
      final m = await showPc(tester);
      m.set(one);
      await tester.pump();
      await tester.tap(find.byKey(const Key('column-local-fold')));
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
      for (final x in [two, const <ServiceSession>[], one]) {
        m.set(x);
        await tester.pump();
        expect(find.byKey(const Key('column-local-folded')), findsOneWidget, reason: '${x.length}');
      }
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      m.set(const []);
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsNothing);
      expect(find.byKey(const Key('column-local-fold')), findsOneWidget);
    });

    TermList terms(List<(String, String?)> rows) => TermList('local', terms: [
          for (final (id, host) in rows) TermRow(id, id.substring(9), 'zsh', host, 1, 0, 1, false, false),
        ]);

    testWidgets('the local column opens itself while a rapp terminal runs', (tester) async {
      await boot(tester);
      final m = await showPc(tester);
      m.setTerms(terms([('term:pty:a', null)]));
      await tester.pump();
      expect(find.byKey(const Key('local-terms')), findsOneWidget);
      expect(find.byKey(const Key('local-term-term:pty:a')), findsOneWidget);
      // The card is the column's first block, above the sessions.
      expect(tester.getTopLeft(find.byKey(const Key('local-terms'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const Key('local-services'))).dy));
      m.setTerms(terms(const []));
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
    });

    testWidgets('rows from other hosts are not shown and do not open the column', (tester) async {
      await boot(tester);
      final m = await showPc(tester);
      m.setTerms(terms([('term:pty@srv:b', 'srv')]));
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      expect(find.byKey(const Key('local-terms')), findsOneWidget);
      expect(find.byKey(const Key('local-term-term:pty@srv:b')), findsNothing);
    });

    testWidgets('no card without terminal support', (tester) async {
      await boot(tester);
      await showPc(tester);
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      expect(find.byKey(const Key('local-terms')), findsNothing);
    });

    testWidgets('新建 on the card opens one on this machine; a second tap while it waits does nothing', (tester) async {
      // The app hands the window and its state the same monitor.
      final m = _Mon();
      await boot(tester, monitor: m);
      await showPc(tester, m);
      m.setTerms(const TermList('local', hosts: [TermHost(null, launchers: ['Terminal'])]));
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('local-terms-new')));
      await tester.pump();
      expect(m.opens, 1);
      await tester.tap(find.byKey(const Key('local-terms-new')));
      await tester.pump();
      expect(m.opens, 1);
      m.gate.complete('term:pty:n');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the open 本机 column shows 连上的服务; the strip does not', (tester) async {
      hubVersion = '0.14.7';
      await boot(tester);
      await show(tester);
      expect(find.byKey(const Key('local-services')), findsNothing);
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      expect(find.byKey(const Key('local-services')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const Key('local-services'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const Key('version-local'))).dy));
    });

    testWidgets('remote columns have no 连上的服务', (tester) async {
      hosts = [{'id': 'm1', 'name': 'mac1'}];
      await boot(tester);
      await show(tester);
      await tester.tap(find.byKey(const Key('column-local-folded')));
      await tester.pump();
      expect(find.descendant(of: find.byKey(const Key('column-m1')), matching: find.byKey(const Key('local-services'))),
          findsNothing);
      expect(find.byKey(const Key('local-services')), findsOneWidget);
    });

    testWidgets('Linux desktop: 本机 folds while idle, opens on inbound with 本机 · :8102 center status, and folds back',
        (tester) async {
      final sync = FakeStateSync(tmp.path)
        ..status = StateStatus.connected
        ..url = Uri.parse('http://127.0.0.1:8102');
      addTearDown(sync.dispose);
      await boot(tester, localOs: DeviceOs.omarchy, stateSync: sync);
      s.toggleOverview();
      final m = _Mon(localId: 'linux999', host: 'linux999')..set(const []);
      addTearDown(m.dispose);
      await tester.pumpWidget(wrap(SizedBox(width: 1194, height: 700, child: Overview(state: s, monitor: m))));
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('column-local'))).width, 56);
      expect(find.byKey(const Key('local-services')), findsNothing);

      m.set(one);
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('column-local'))).width, 220);
      expect(find.byKey(const Key('local-services')), findsOneWidget);
      expect(find.text('本机 · :8102'), findsOneWidget);
      expect(find.text('LLM 网关'), findsOneWidget);

      m.set(const []);
      await tester.pump();
      expect(find.byKey(const Key('column-local-folded')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });
}

/// A monitor that never connects: the test sets who is connected in.
class _Mon extends ServiceMonitor {
  _Mon({this.localId, this.host}) : super(readToken: () async => null);
  final String? localId;
  final String? host;

  void set(List<ServiceSession> sessions) {
    status = ServiceStatus(id: localId, sessions: sessions);
    notifyListeners();
  }

  void setTerms(TermList? l) {
    localTerms = l;
    notifyListeners();
  }

  @override
  Future<String?> stateHost() async => host;

  var opens = 0;
  final gate = Completer<String>();

  @override
  Future<String> termOpen({String? shell, required String app, String? from}) {
    opens++;
    return gate.future;
  }
}

class _Fs implements FullscreenControl {
  @override
  Stream<bool> get changes => const Stream.empty();
  @override
  Future<bool> isFullScreen() async => false;
  @override
  Future<void> setFullScreen(bool v) async {}
}
