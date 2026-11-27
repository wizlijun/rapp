import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/embed/strip_tools.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/phrases_page.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/star_button.dart';

import '../fakes.dart';
import 'helpers.dart';

const _oldTen = [
  Phrase('继续'), Phrase('确认'), Phrase('听你的'), Phrase('按你推荐的来'), Phrase('进度'),
  Phrase('全部做完，中途不用问我'), Phrase('先出方案，别改代码'), Phrase('跑一下测试'), Phrase('提交并推送'), Phrase('总结一下改了什么'),
];

void main() {
  late Directory tmp;
  late MainState s;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('phrases_page_test');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort());
    s.setStripItems(_oldTen); // the list these tests were written for: phrases only
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
      builder: (c) => TextButton(onPressed: () => openPhrasesPage(c, s), child: const Text('go')),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  List<String> texts() => [for (final p in s.quick.phrases.whereType<Phrase>()) p.text];

  testWidgets('star on the phrases page stars the item', (tester) async {
    await open(tester);
    final r0 = refOf(s.quick.phrases[0]);
    final r2 = refOf(s.quick.phrases[2]);
    await tester.tap(find.byKey(const Key('phrases-star-0')));
    await tester.pumpAndSettle();
    expect(s.quick.stars, [r0]);
    expect(find.byTooltip('取消星标'), findsOneWidget);
    await tester.tap(find.byKey(const Key('phrases-star-2')));
    await tester.pumpAndSettle();
    expect(s.quick.stars, [r0, r2]);
    await tester.tap(find.byKey(const Key('phrases-star-0')));
    await tester.pumpAndSettle();
    expect(s.quick.stars, [r2]);
    // reorder: the star follows the phrase, not the row
    s.setStripItems([s.quick.phrases[1], ...s.quick.phrases.sublist(2), s.quick.phrases[0]]);
    await tester.pumpAndSettle();
    expect(s.quick.stars, [r2]);
    expect(find.byTooltip('取消星标'), findsOneWidget);
    expect(tester.widget<StarButton>(find.byKey(const Key('phrases-star-1'))).starred, isTrue);
    expect(find.descendant(of: find.byKey(const Key('phrases-star-1')), matching: find.byTooltip('取消星标')), findsOneWidget);
    // The one star of 快捷区, as on the keys page and in the menus.
    for (var i = 0; i < s.quick.phrases.length; i++) {
      expect(tester.widget(find.byKey(Key('phrases-star-$i'))), isA<StarButton>());
    }
  });

  testWidgets('the switch turns the strip off; the list is the defaults', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('phrase-row-9')), findsOneWidget);
    expect(find.textContaining('回车会选中当前高亮的那一项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('phrase-strip-switch')));
    await tester.pumpAndSettle();
    expect(s.prefs.phraseStrip, isFalse);
  });

  testWidgets('＋ 新增: empty cannot be saved; 放进输入框 saves put', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('phrase-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phrase-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrase-text')), findsOneWidget); // still open
    await tester.enterText(find.byKey(const Key('phrase-text')), '  帮我看看日志  ');
    await tester.tap(find.byKey(const Key('phrase-put')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('phrase-save')));
    await tester.pumpAndSettle();
    expect(s.quick.phrases.last, const Phrase('帮我看看日志', put: true));
    expect(s.quick.phrases, hasLength(_oldTen.length + 1));
  });

  testWidgets('tap a row edits it; swipe deletes; 恢复默认 brings the defaults back', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('phrase-row-0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('phrase-text')), '接着做');
    await tester.tap(find.byKey(const Key('phrase-save')));
    await tester.pumpAndSettle();
    expect(texts().first, '接着做');

    await tester.drag(find.byKey(const Key('phrase-row-1')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(texts(), isNot(contains('确认')));
    expect(texts(), hasLength(_oldTen.length - 1));

    await tester.tap(find.byKey(const Key('phrase-reset')));
    await tester.pumpAndSettle();
    expect(s.quick.phrases, defaultQuickPhrases);
  });

  group('commands on the page', () {
    setUp(() => s.setStripItems(defaultStripItems));

    List<StripCmd> cmds() => s.quick.phrases.whereType<StripCmd>().toList();
    StripCmd cmd(String id) => cmds().firstWhere((c) => c.id == id);
    Finder k(String key) => find.byKey(Key(key));

    Future<void> tapK(WidgetTester tester, String key) async {
      await tester.ensureVisible(k(key));
      await tester.tap(k(key));
      await tester.pumpAndSettle();
    }

    testWidgets('mixed list: tags, subtitles, and the note', (tester) async {
      await open(tester);
      expect(k('phrase-cmd-tag-0'), findsOneWidget);
      expect(k('phrase-cmd-tag-7'), findsNothing);
      expect(find.textContaining('Claude Code /clear · Codex /new'), findsOneWidget);
      expect(find.textContaining('Codex ⌃R'), findsOneWidget);
      expect(find.text('命令只在文字终端里认出 Claude Code、Codex 等工具时出现。'), findsOneWidget);
    });

    testWidgets('deleting a phrase keeps the six commands in order', (tester) async {
      await open(tester);
      await tester.drag(k('phrase-row-7'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect([for (final c in cmds()) c.id], builtinCmdOrder);
      expect(s.quick.phrases.take(7).every((e) => e is StripCmd), isTrue);
      expect(s.quick.phrases, hasLength(defaultStripItems.length - 1));
    });

    testWidgets('editing a phrase keeps the commands', (tester) async {
      await open(tester);
      await tester.tap(k('phrase-row-7'));
      await tester.pumpAndSettle();
      await tester.enterText(k('phrase-text'), '改了');
      await tester.tap(k('phrase-save'));
      await tester.pumpAndSettle();
      expect([for (final c in cmds()) c.id], builtinCmdOrder);
      expect(s.quick.phrases[7], const Phrase('改了'));
    });

    testWidgets('dragging a phrase before a command reorders the whole list', (tester) async {
      await open(tester);
      final first = s.quick.phrases[7];
      final handle = find.descendant(of: k('phrase-row-7'), matching: find.byIcon(Icons.drag_handle));
      await tester.drag(handle, const Offset(0, -7 * 72.0 - 40));
      await tester.pumpAndSettle();
      expect(s.quick.phrases.first, first);
      expect(s.quick.phrases[1], isA<StripCmd>());
    });

    testWidgets('＋ 新增命令', (tester) async {
      await open(tester);
      await tapK(tester, 'phrase-cmd-add');
      expect(tester.widget<RappButton>(k('phrase-cmd-save')).onPressed,
          isNull);
      await tester.enterText(k('phrase-cmd-label'), '审查');
      await tester.enterText(k('phrase-cmd-tool-codex'), '/review');
      await tester.pump();
      await tester.tap(k('phrase-cmd-save'));
      await tester.pumpAndSettle();
      final c = s.quick.phrases.last as StripCmd;
      expect(c.labelOf(), '审查');
      expect(actionFor(c, agentTools.firstWhere((t) => t.id == 'codex')), const CmdText('/review'));
    });

    testWidgets('edit a built-in: change, reset a cell; clear a cell', (tester) async {
      await open(tester);
      await tester.tap(k('phrase-row-0'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(k('phrase-cmd-label')).controller!.text, '新对话');
      await tester.enterText(k('phrase-cmd-tool-codex'), '/clear');
      await tester.pump();
      await tester.tap(k('phrase-cmd-save'));
      await tester.pumpAndSettle();
      expect(cmd('new').per['codex'], const CmdText('/clear'));
      expect(cmd('new').label, isNull);

      await tester.tap(k('phrase-row-0'));
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
      await tester.tap(k('phrase-row-0'));
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
      await tester.tap(k('phrase-row-0'));
      await tester.pumpAndSettle();
      await tester.enterText(k('phrase-cmd-label'), '');
      await tester.pump();
      expect(tester.widget<RappButton>(k('phrase-cmd-save')).onPressed,
          isNull);
    });

    testWidgets('恢复默认', (tester) async {
      final go = s.quick.phrases.whereType<Phrase>().firstWhere((p) => p.text == '提交并推送');
      s.toggleStar(refOf(go));
      await open(tester);
      await tester.drag(k('phrase-row-7'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.tap(k('phrase-reset'));
      await tester.pumpAndSettle();
      expect(s.quick.phrases, defaultQuickPhrases);
      expect(s.quick.stars, [refOf(go)], reason: 'a default item keeps its star');
    });
  });
}
