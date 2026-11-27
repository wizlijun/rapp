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

  iosTest('claude in front: the commands come first, with 「命令：」 semantics', (tester) async {
    await tester.pumpWidget(strip(tsess));
    // Nothing counted yet: the six commands lead the row, then the phrases; 搜历史 is a 按键动作 now, not among them.
    expect(find.descendant(of: ph('phrase-0'), matching: find.text('新对话')), findsOneWidget);
    expect(find.descendant(of: ph('phrase-1'), matching: find.text('切模式')), findsOneWidget);
    expect(find.descendant(of: ph('phrase-5'), matching: find.text('用量')), findsOneWidget);
    expect(find.descendant(of: ph('phrase-6'), matching: find.text('继续')), findsOneWidget);
    final xs = [for (var i = 0; i <= 6; i++) tester.getTopLeft(ph('phrase-$i')).dx];
    expect(xs, [...xs]..sort());
    expect(xs.first, tester.getTopLeft(ph('phrase-strip-list')).dx);
    expect(find.bySemanticsLabel('命令：新对话'), findsOneWidget);
    expect(find.descendant(of: ph('phrase-strip-list'), matching: find.text('搜历史')), findsNothing,
        reason: 'the key actions come after the phrases, out of sight at this width');
  });

  iosTest('back to the shell: commands go, the first is 继续, the bar is as high', (tester) async {
    final h = keyBarHeightOf(s, tsess);
    fg('zsh', shell: true);
    s.setStripItems(List.of(s.quick.phrases)); // notify
    await tester.pumpWidget(strip(tsess));
    expect(find.text('新对话'), findsNothing);
    // 搜历史 went to the 按键动作 (quick-row): 继续 is the seventh of the list.
    expect(find.descendant(of: ph('phrase-6'), matching: find.text('继续')), findsOneWidget);
    expect(keyBarHeightOf(s, tsess), h);
  });

  iosTest('phraseStripShown: commands only and no tool in front: the strip shows, its commands do not', (tester) async {
    s.setStripItems([for (final c in defaultStripItems.whereType<StripCmd>()) c]);
    fg('zsh', shell: true);
    expect(phraseStripShown(s, tsess), isTrue, reason: 'the two menus are of use alone (quick-row §5.1)');
    await tester.pumpWidget(strip(tsess));
    expect(find.text('新对话'), findsNothing);
    expect(ph('quick-menu-phrases'), findsOneWidget);
    fg('claude');
    s.setStripItems(List.of(s.quick.phrases)); // notify
    await tester.pump();
    expect(phraseStripShown(s, tsess), isTrue);
    expect(find.descendant(of: ph('phrase-0'), matching: find.text('新对话')), findsOneWidget);
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

  iosTest('long press on a command: 编辑 · 打星 · 删除 (移到最前 once starred); 打星 and 删除 keep the order', (tester) async {
    await tester.pumpWidget(strip(tsess));
    await tester.longPress(ph('phrase-3'));
    await tester.pumpAndSettle();
    expect(ph('phrase-menu-put'), findsNothing);
    expect(ph('phrase-menu-edit'), findsOneWidget);
    expect(ph('phrase-menu-first'), findsNothing);
    await tester.tap(ph('phrase-menu-star'));
    await tester.pumpAndSettle();
    expect(s.quick.stars, ['p:compact']);
    expect((s.quick.phrases.first as StripCmd).id, 'new', reason: 'a star leaves the list as it was');
    await tester.longPress(ph('phrase-3'));
    await tester.pumpAndSettle();
    expect(ph('phrase-menu-first'), findsOneWidget);
    await tester.tap(ph('phrase-menu-delete'));
    await tester.pumpAndSettle();
    expect((s.quick.phrases.first as StripCmd).id, 'new');
    expect((s.quick.phrases[3] as StripCmd).id, 'resume');
    expect(s.quick.phrases.whereType<StripCmd>(), hasLength(5)); // six without 搜历史 (quick-row), one deleted
    expect(s.quick.stars, isEmpty);
  });

  iosTest('long press on a key action: 编辑 renames it and keeps its id and per', (tester) async {
    await tester.pumpWidget(strip(tsess));
    final list = find.descendant(of: ph('phrase-strip-list'), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(ph('keyact-search'), 200, scrollable: list);
    await tester.pump();
    final per = s.quick.keys.firstWhere((a) => a.id == 'search').per;
    expect(per, isNotEmpty);
    await tester.longPress(ph('keyact-search'));
    await tester.pumpAndSettle();
    await tester.tap(ph('keyact-menu-edit'));
    await tester.pumpAndSettle();
    await tester.enterText(ph('keyact-name'), '找历史');
    await tester.tap(ph('keyact-save'));
    await tester.pumpAndSettle();
    final a = s.quick.keys.firstWhere((a) => a.id == 'search');
    expect(a.label, '找历史');
    expect(a.per, per);
    expect(s.quick.keys.map((k) => k.id).toList().indexOf('search'), 0);
  });

  iosTest('常用语▾: lists commands when a tool is recognised, grey under zsh (spec §5.4)', (tester) async {
    await tester.pumpWidget(strip(tsess));
    await tester.tap(ph('quick-menu-phrases'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(ListTile), matching: find.text('新对话')), findsOneWidget);
    Navigator.of(tester.element(find.byType(ListTile).first)).pop();
    await tester.pumpAndSettle();
    fg('zsh', shell: true);
    s.setStripItems(List.of(s.quick.phrases));
    await tester.pump();
    await tester.tap(ph('quick-menu-phrases'));
    await tester.pumpAndSettle();
    final cmd = find.ancestor(of: find.text('新对话'), matching: find.byType(ListTile));
    expect(cmd, findsOneWidget);
    expect(find.ancestor(of: cmd, matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1)), findsOneWidget);
    expect(find.descendant(of: find.byType(ListTile), matching: find.text('继续')), findsOneWidget);
  });

  iosTest('an app session with 常用语条 on shows no commands', (tester) async {
    app.setProfile(const ResolvedProfile(phrases: true));
    await tester.pumpWidget(strip(app));
    expect(find.text('新对话'), findsNothing);
    expect(find.descendant(of: ph('phrase-6'), matching: find.text('继续')), findsOneWidget); // 搜历史 is a 按键动作 now
  });

  testWidgets('linux desktop KeyBar sends tool commands, and Ctrl-R from the 搜历史 key action, while preserving TextField caret',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      final focus = FocusNode();
      final ctl = TextEditingController(text: '草稿文字');
      addTearDown(() {
        focus.dispose();
        ctl.dispose();
      });
      await tester.pumpWidget(wrap(Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 400, child: TextField(focusNode: focus, controller: ctl)),
        SizedBox(width: 900, child: KeyBar(state: s, session: tsess, port: term)),
      ])));
      focus.requestFocus();
      await tester.pump();
      ctl.selection = const TextSelection(baseOffset: 1, extentOffset: 3);
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      // Claude Code: 新对话 sends /clear via terminal paste, caret and selection stay in the editor.
      await tester.tap(ph('phrase-0'));
      await tester.pump();
      expect(term.calls.where((c) => c.$1 == 'paste').last.$2['data'], '/clear');
      tsess.composer.done(1, null);
      expect(focus.hasFocus, isTrue);
      expect(ctl.selection, const TextSelection(baseOffset: 1, extentOffset: 3));

      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1050)));
      // Claude Code: the 搜历史 key action (after the commands and phrases) sends Ctrl-R over TermSessionPort.
      final list = find.descendant(of: ph('phrase-strip-list'), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(ph('keyact-search'), 200, scrollable: list);
      await tester.pump();
      await tester.tap(ph('keyact-search'));
      await tester.pump();
      expect(term.calls.where((c) => c.$1 == 'keys').last.$2['keys'], ['Ctrl-R']);
      expect(focus.hasFocus, isTrue);
      expect(ctl.selection, const TextSelection(baseOffset: 1, extentOffset: 3));

      await tester.pump(const Duration(seconds: 3));
      // Antigravity (agy) on Linux: 搜历史 is unsupported -> off the row, the next key action stays; bash hides commands.
      fg('agy');
      s.setStripItems(List.of(s.quick.phrases));
      await tester.pump();
      expect(ph('keyact-search'), findsNothing);
      expect(ph('keyact-expand'), findsOneWidget);
      expect(focus.hasFocus, isTrue);

      fg('bash', shell: true);
      s.setStripItems(List.of(s.quick.phrases));
      await tester.pump();
      expect(find.text('新对话'), findsNothing);
      // No tool in front: the plain ⌃R is back, and first, since it was used once (the list changed, so it was re-counted).
      await tester.scrollUntilVisible(ph('keyact-search'), -200, scrollable: list);
      expect(tester.getTopLeft(ph('keyact-search')).dx, lessThan(tester.getTopLeft(ph('phrase-6')).dx));
      expect(focus.hasFocus, isTrue);
      expect(ctl.selection, const TextSelection(baseOffset: 1, extentOffset: 3));
    } finally {
      tester.view.reset();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
