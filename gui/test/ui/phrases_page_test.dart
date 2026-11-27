import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/phrases_page.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/quick_prefs.dart';
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

  testWidgets('tap a row edits it; swipe deletes; 恢复默认 brings the default phrases back, adds no command', (tester) async {
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
    expect(s.quick.phrases, defaultQuickPhrases.whereType<Phrase>().toList());
  });

  group('the page holds the phrases only; the commands stay where they are', () {
    setUp(() => s.setStripItems(defaultQuickPhrases));

    List<String> cmdIds() => [for (final c in s.quick.phrases.whereType<StripCmd>()) c.id];
    List<StripItem> cmdsNow() => s.quick.phrases.whereType<StripCmd>().toList();
    Finder k(String key) => find.byKey(Key(key));

    testWidgets('rows are the phrases, in order; no command, no 新增命令', (tester) async {
      await open(tester);
      final ps = s.quick.phrases.whereType<Phrase>().toList();
      for (final (i, p) in ps.indexed) {
        expect(find.descendant(of: k('phrase-row-$i'), matching: find.text(p.text)), findsOneWidget);
      }
      expect(k('phrase-row-${ps.length}'), findsNothing);
      expect(find.text('命令'), findsNothing, reason: 'no 命令 tag');
      expect(find.text('新对话'), findsNothing);
      expect(k('phrase-cmd-add'), findsNothing);
      expect(k('phrase-add'), findsOneWidget);
    });

    testWidgets('delete / edit a phrase: the commands keep their slots', (tester) async {
      final before = List.of(s.quick.phrases);
      await open(tester);
      await tester.drag(k('phrase-row-0'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(s.quick.phrases, [for (final it in before) if (it != before.whereType<Phrase>().first) it]);
      await tester.tap(k('phrase-row-0'));
      await tester.pumpAndSettle();
      await tester.enterText(k('phrase-text'), '改了');
      await tester.tap(k('phrase-save'));
      await tester.pumpAndSettle();
      expect(cmdIds(), builtinCmdOrder);
      expect(s.quick.phrases.whereType<Phrase>().first, const Phrase('改了'));
      expect(s.quick.phrases.take(7).every((e) => e is StripCmd), isTrue);
    });

    testWidgets('drag reorders the phrases among themselves', (tester) async {
      await open(tester);
      final ps = s.quick.phrases.whereType<Phrase>().toList();
      final handle = find.descendant(of: k('phrase-row-2'), matching: find.byIcon(Icons.drag_handle));
      await tester.drag(handle, const Offset(0, -2 * 72.0 - 40));
      await tester.pumpAndSettle();
      expect(s.quick.phrases.whereType<Phrase>().first, ps[2]);
      expect(s.quick.phrases.take(7).every((e) => e is StripCmd), isTrue);
    });

    testWidgets('a new phrase goes at the end; 恢复默认 leaves the commands alone and keeps stars', (tester) async {
      final go = s.quick.phrases.whereType<Phrase>().firstWhere((p) => p.text == '提交并推送');
      s.toggleStar(refOf(go));
      s.setStripItems([for (final it in s.quick.phrases) if (!(it is StripCmd && it.id == 'usage')) it]);
      final cmds = cmdsNow();
      await open(tester);
      await tester.ensureVisible(k('phrase-add'));
      await tester.tap(k('phrase-add'));
      await tester.pumpAndSettle();
      await tester.enterText(k('phrase-text'), '新的');
      await tester.pump();
      await tester.tap(k('phrase-save'));
      await tester.pumpAndSettle();
      expect(s.quick.phrases.last, const Phrase('新的'));
      await tester.ensureVisible(k('phrase-reset'));
      await tester.tap(k('phrase-reset'));
      await tester.pumpAndSettle();
      expect(cmdsNow(), cmds, reason: '常用语的恢复默认不动命令');
      expect(s.quick.phrases.whereType<Phrase>().toList(), defaultQuickPhrases.whereType<Phrase>().toList());
      expect(s.quick.stars, [refOf(go)], reason: 'a default item keeps its star');
    });
  });
}
