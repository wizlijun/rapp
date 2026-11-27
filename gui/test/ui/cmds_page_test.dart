// 全局设置 → 命令 (cmd-menu design): the commands of the one 常用语 doc, on a page of their own.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/embed/strip_tools.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/cmds_page.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/star_button.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late Directory tmp;
  late MainState s;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cmds_page_test');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort());
    s.setStripItems(defaultQuickPhrases);
  });

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(Builder(
      builder: (c) => TextButton(onPressed: () => openCmdsPage(c, s), child: const Text('go')),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  List<StripCmd> cmds() => s.quick.phrases.whereType<StripCmd>().toList();
  List<Phrase> phrases() => s.quick.phrases.whereType<Phrase>().toList();
  StripCmd cmd(String id) => cmds().firstWhere((c) => c.id == id);
  Finder k(String key) => find.byKey(Key(key));

  Future<void> tapK(WidgetTester tester, String key) async {
    await tester.ensureVisible(k(key));
    await tester.tap(k(key));
    await tester.pumpAndSettle();
  }

  testWidgets('rows are the commands with what each tool gets; no phrase, no strip switch', (tester) async {
    await open(tester);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('命令')), findsOneWidget);
    for (final (i, c) in cmds().indexed) {
      expect(find.descendant(of: k('cmd-row-$i'), matching: find.text(c.labelOf())), findsOneWidget);
    }
    expect(k('cmd-row-${cmds().length}'), findsNothing);
    expect(find.text('继续'), findsNothing);
    expect(find.textContaining('Claude Code /clear · Codex /new'), findsOneWidget);
    expect(find.textContaining('Codex ⌃R'), findsOneWidget, reason: '搜历史 is a command again');
    expect(find.text('命令只在文字终端里认出 Claude Code、Codex 等工具时出现。'), findsOneWidget);
    expect(k('phrase-strip-switch'), findsNothing);
    expect(k('phrase-add'), findsNothing);
  });

  testWidgets('the star is the shared StarButton', (tester) async {
    await open(tester);
    expect(tester.widget(k('cmds-star-1')), isA<StarButton>());
    await tester.tap(k('cmds-star-1'));
    await tester.pumpAndSettle();
    expect(s.quick.stars, [refOf(cmds()[1])]);
  });

  testWidgets('＋ 新增命令 goes after the last command, before the phrases', (tester) async {
    await open(tester);
    await tapK(tester, 'cmd-add');
    expect(tester.widget<RappButton>(k('phrase-cmd-save')).onPressed, isNull);
    await tester.enterText(k('phrase-cmd-label'), '审查');
    await tester.enterText(k('phrase-cmd-tool-codex'), '/review');
    await tester.pump();
    await tester.tap(k('phrase-cmd-save'));
    await tester.pumpAndSettle();
    final c = cmds().last;
    expect(c.labelOf(), '审查');
    expect(actionFor(c, agentTools.firstWhere((t) => t.id == 'codex')), const CmdText('/review'));
    expect(s.quick.phrases[builtinCmdOrder.length], c);
    expect(phrases(), defaultQuickPhrases.whereType<Phrase>().toList());
  });

  testWidgets('swipe deletes a command, drag reorders the commands; the phrases stay', (tester) async {
    await open(tester);
    await tester.drag(k('cmd-row-1'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect([for (final c in cmds()) c.id], [for (final id in builtinCmdOrder) if (id != 'mode') id]);
    final handle = find.descendant(of: k('cmd-row-2'), matching: find.byIcon(Icons.drag_handle));
    await tester.drag(handle, const Offset(0, -400)); // past the top
    await tester.pumpAndSettle();
    expect(cmds().first.id, 'compact');
    expect(phrases(), defaultQuickPhrases.whereType<Phrase>().toList());
    expect(s.quick.phrases.take(cmds().length).every((e) => e is StripCmd), isTrue);
  });

  testWidgets('edit a built-in: change, reset a cell; clear a cell', (tester) async {
    await open(tester);
    await tester.tap(k('cmd-row-0'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(k('phrase-cmd-label')).controller!.text, '新对话');
    await tester.enterText(k('phrase-cmd-tool-codex'), '/clear');
    await tester.pump();
    await tester.tap(k('phrase-cmd-save'));
    await tester.pumpAndSettle();
    expect(cmd('new').per['codex'], const CmdText('/clear'));
    expect(cmd('new').label, isNull);

    await tester.tap(k('cmd-row-0'));
    await tester.pumpAndSettle();
    expect(k('phrase-cmd-row-reset-codex'), findsOneWidget);
    expect(k('phrase-cmd-row-reset-claude-code'), findsNothing);
    await tester.tap(k('phrase-cmd-row-reset-codex'));
    await tester.pump();
    await tester.enterText(k('phrase-cmd-tool-claude-code'), '');
    await tester.pump();
    await tester.tap(k('phrase-cmd-save'));
    await tester.pumpAndSettle();
    expect(cmd('new').per.containsKey('codex'), isFalse);
    expect(cmd('new').per.containsKey('claude-code'), isTrue);
    expect(cmd('new').per['claude-code'], isNull);
  });

  testWidgets('a tool can send a key', (tester) async {
    await open(tester);
    await tester.tap(k('cmd-row-0'));
    await tester.pumpAndSettle();
    await tapK(tester, 'phrase-cmd-mode-codex');
    for (final id in ['cr', 'co', 'ct', 'cb', 'cl', 'stab', 'tab', 'esc', 'cc']) {
      expect(k('phrase-cmd-key-codex-$id'), findsOneWidget, reason: id);
    }
    await tapK(tester, 'phrase-cmd-key-codex-cr');
    await tester.tap(k('phrase-cmd-save'));
    await tester.pumpAndSettle();
    expect(cmd('new').per['codex'], const CmdKey('cr'));
  });

  testWidgets('empty face: save is off', (tester) async {
    await open(tester);
    await tester.tap(k('cmd-row-0'));
    await tester.pumpAndSettle();
    await tester.enterText(k('phrase-cmd-label'), '');
    await tester.pump();
    expect(tester.widget<RappButton>(k('phrase-cmd-save')).onPressed, isNull);
  });

  testWidgets('恢复默认 brings the built-in commands back, leaves the phrases alone, keeps stars', (tester) async {
    s.toggleStar(refOf(cmd('compact')));
    s.setStripItems([...s.quick.phrases.where((it) => !(it is StripCmd && it.id == 'usage')), const Phrase('我自己的')]);
    final ps = phrases();
    await open(tester);
    await tester.tap(k('cmd-row-0'));
    await tester.pumpAndSettle();
    await tester.enterText(k('phrase-cmd-tool-codex'), '/clear');
    await tester.tap(k('phrase-cmd-save'));
    await tester.pumpAndSettle();
    await tapK(tester, 'cmd-reset');
    expect([for (final c in cmds()) c.id], builtinCmdOrder);
    expect(cmd('new').per, isEmpty);
    expect(phrases(), ps);
    expect(s.quick.stars, [refOf(cmd('compact'))]);
  });

  testWidgets('Linux desktop: CmdsPage lists all 7 built-in commands including 搜历史 and migrates 0.15.63/64 keys doc',
      variant: TargetPlatformVariant.only(TargetPlatform.linux), (tester) async {
    await tester.runAsync(() async {
      final migDir = Directory('${tmp.path}/mig')..createSync();
      File('${migDir.path}/quick.json').writeAsStringSync(
        '{"v":1,'
        '"phrases":{"at":10,"data":[{"cmd":"new"},{"text":"继续","id":"p1"}]},'
        '"keys":{"at":10,"data":[{"id":"search","label":"翻历史"},{"id":"clear","label":"清屏"}]},'
        '"layout":{"at":10,"data":{"rows":[["tab","k:clear","esc"],["copy"]]}},'
        '"stars":{"at":10,"data":["k:search","k:clear"]},'
        '"usage":{"at":10,"data":{"k:search":{"2026-11-27":3},"k:clear":{"2026-11-27":2}}}}',
      );
      final q = QuickPrefs.load(migDir.path, legacy: const []);
      expect(q.phrases.whereType<StripCmd>().any((c) => c.id == 'search' && c.label == '翻历史'), isTrue);
      expect(q.stars, ['p:search']);
      expect(q.layout.rows[0], ['tab', 'esc']);
      expect(q.usage, {'p:search': {'2026-11-27': 3}});
      expect(File('${migDir.path}/quick.json').readAsStringSync().contains('"keys"'), isFalse);
    });
    await open(tester);
    expect(find.text('新对话'), findsOneWidget);
    expect(find.text('搜历史'), findsOneWidget);
    expect([for (final c in cmds()) c.id], builtinCmdOrder);
  });
}
