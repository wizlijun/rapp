// 常用语条 commands (strip-commands spec §4, §5): shown for the foreground tool of a pty terminal, grey where the tool
// has none, a smaller long-press menu.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/phrase_strip.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  late Directory tmp;
  late RemoteSession tsess, app;

  TermRow row(String fg, {required bool shell}) =>
      TermRow('term:pty:w', 'w', 'zsh', null, 1, 1, 0, false, false, fg: fg, shell: shell);
  void fg(String fg, {bool shell = false}) => hub.termLists['111'] = TermList('111', terms: [row(fg, shell: shell)]);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('phrase_strip_cmds_test');
    t = FakeTransport();
    hub = HubClient(t);
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    t.emit({'event': 'hosts', 'hosts': [{'id': '111', 'name': 'mini'}]});
    await Future<void>.delayed(Duration.zero);
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(phrases: defaultStripItems), port: port, termPort: term);
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({'event': 'opened', 'sid': 1, 'id': '111', 'app': m['app'], 'path': 'lan', 'port': 5011, 'token': 'tk', 'req': m['req']});
      }
    };
    await s.openOrSwitch('111', 'term:pty:w', 'w');
    await Future<void>.delayed(Duration.zero);
    term.seed(1);
    tsess = RemoteSession(1, 'w');
    app = RemoteSession(3, 'Notes');
    fg('claude');
  });

  tearDown(() {
    tsess.dispose();
    app.dispose();
    s.dispose();
    term.dispose();
    tmp.deleteSync(recursive: true);
  });

  void iosTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
          tester.view.physicalSize = const Size(1000, 900);
          tester.view.devicePixelRatio = 1;
          await tester.runAsync(() async {});
          await body(tester);
        } finally {
          tester.view.reset();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Widget strip(RemoteSession rs) => wrap(SizedBox(
      width: 900,
      child: PhraseStrip(state: s, session: rs, port: rs == tsess ? term : port)));
  Finder ph(String id) => find.byKey(Key(id));

  iosTest('claude in front: the first six are commands, with 「命令：」 semantics', (tester) async {
    await tester.pumpWidget(strip(tsess));
    expect(find.descendant(of: ph('phrase-0'), matching: find.text('新对话')), findsOneWidget);
    expect(find.descendant(of: ph('phrase-5'), matching: find.text('搜历史')), findsOneWidget);
    expect(find.descendant(of: ph('phrase-6'), matching: find.text('继续')), findsOneWidget);
    expect(find.bySemanticsLabel('命令：新对话'), findsOneWidget);
  });

  iosTest('back to the shell: commands go, the first is 继续, the bar is as high', (tester) async {
    final h = keyBarHeightOf(s, tsess);
    fg('zsh', shell: true);
    s.setStripItems(List.of(s.prefs.phrases)); // notify
    await tester.pumpWidget(strip(tsess));
    expect(find.text('新对话'), findsNothing);
    expect(find.descendant(of: ph('phrase-6'), matching: find.text('继续')), findsOneWidget);
    expect(keyBarHeightOf(s, tsess), h);
  });

  iosTest('phraseStripShown: commands only show with a tool in front', (tester) async {
    s.setStripItems([for (final c in defaultStripItems.whereType<StripCmd>()) c]);
    fg('zsh', shell: true);
    expect(phraseStripShown(s, tsess), isFalse);
    fg('claude');
    expect(phraseStripShown(s, tsess), isTrue);
  });

  iosTest('Codex without 新对话: grey, and a tap says so', (tester) async {
    fg('codex');
    s.setStripItems([const StripCmd('new', per: {'codex': null}), ...defaultStripItems.skip(1)]);
    await tester.pumpWidget(strip(tsess));
    expect(find.ancestor(of: find.text('新对话'), matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1)),
        findsOneWidget);
    await tester.tap(ph('phrase-0'));
    await tester.pump();
    expect(tester.widget<Text>(ph('phrase-hint')).data, 'Codex 没有这个命令');
    await tester.pump(const Duration(seconds: 5));
  });

  iosTest('long press on a command: 编辑 · 移到最前 · 删除 only; 移到最前 and 删除 keep the order', (tester) async {
    await tester.pumpWidget(strip(tsess));
    await tester.longPress(ph('phrase-2'));
    await tester.pumpAndSettle();
    expect(ph('phrase-menu-put'), findsNothing);
    expect(ph('phrase-menu-edit'), findsOneWidget);
    await tester.tap(ph('phrase-menu-first'));
    await tester.pumpAndSettle();
    expect((s.prefs.phrases.first as StripCmd).id, 'compact');
    expect((s.prefs.phrases[1] as StripCmd).id, 'new');
    await tester.longPress(ph('phrase-0'));
    await tester.pumpAndSettle();
    await tester.tap(ph('phrase-menu-delete'));
    await tester.pumpAndSettle();
    expect((s.prefs.phrases.first as StripCmd).id, 'new');
    expect(s.prefs.phrases.whereType<StripCmd>(), hasLength(5));
  });

  iosTest('全部 ›: lists commands when a tool is recognised, none under zsh', (tester) async {
    await tester.pumpWidget(strip(tsess));
    await tester.tap(ph('phrases-all'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(ListTile), matching: find.text('新对话')), findsOneWidget);
    Navigator.of(tester.element(find.byType(ListTile).first)).pop();
    await tester.pumpAndSettle();
    fg('zsh', shell: true);
    s.setStripItems(List.of(s.prefs.phrases));
    await tester.pump();
    await tester.tap(ph('phrases-all'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(ListTile), matching: find.text('新对话')), findsNothing);
    expect(find.descendant(of: find.byType(ListTile), matching: find.text('继续')), findsOneWidget);
  });

  iosTest('an app session with 常用语条 on shows no commands', (tester) async {
    app.setProfile(const ResolvedProfile(phrases: true));
    await tester.pumpWidget(strip(app));
    expect(find.text('新对话'), findsNothing);
    expect(find.descendant(of: ph('phrase-6'), matching: find.text('继续')), findsOneWidget);
  });
}
