// The 快捷区 first row (quick-row spec §5, cmd-menu design): the chips in front (the starred, or every item by use
// count), and the two menus 「命令▾」「常用语▾」 pinned at its right end.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/phrase_strip.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/cmds_page.dart';
import 'package:rapp/pages/phrases_page.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/quick_row.dart';
import 'package:rapp/quick/quick_usage.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/star_button.dart';

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
    tmp = Directory.systemTemp.createTempSync('quick_row_widget_test');
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
          // Wide enough that every chip is built (the order is read off the screen), tall enough for a whole sheet.
          tester.view.physicalSize = const Size(3200, 2400);
          tester.view.devicePixelRatio = 1;
          await tester.runAsync(() async {});
          await body(tester);
        } finally {
          tester.view.reset();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Widget strip(RemoteSession rs) =>
      wrap(SizedBox(width: 3100, child: PhraseStrip(state: s, session: rs, port: rs == tsess ? term : port)));
  Finder ph(String id) => find.byKey(Key(id));

  /// The chip keys of the row, left to right.
  List<String> rowKeys(WidgetTester tester) {
    final f = find.descendant(
      of: ph('phrase-strip-list'),
      matching: find.byWidgetPredicate((w) {
        final k = w.key;
        return w is GestureDetector &&
            k is ValueKey<String> &&
            k.value.startsWith('phrase-');
      }),
    );
    final els = f.evaluate().toList()
      ..sort((a, b) => (a.renderObject! as RenderBox)
          .localToGlobal(Offset.zero)
          .dx
          .compareTo((b.renderObject! as RenderBox).localToGlobal(Offset.zero).dx));
    return [for (final e in els) ((e.widget.key!) as ValueKey<String>).value];
  }

  /// quickRowOrder's answer for the state now, as chip keys (commands only with a tool).
  List<String> expectedKeys({required bool tool}) {
    final q = s.quick;
    final order = quickRowOrder(
      refs: [for (final p in q.phrases) refOf(p)],
      stars: q.stars,
      totals: usageTotals([q.usage, ...q.others.values], DateTime.now()),
    );
    return [
      for (final r in order)
        for (final (i, it) in q.phrases.indexed)
          if (refOf(it) == r && (it is Phrase || tool)) 'phrase-$i',
    ];
  }

  int indexOfCmd(String id) => s.quick.phrases.indexWhere((it) => it is StripCmd && it.id == id);

  /// The rows of the open sheet, top to bottom, as `menu-p-<i>` keys.
  List<String> sheetRows(WidgetTester tester) {
    final els = find
        .byWidgetPredicate((w) => w is ListTile && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('menu-p-'))
        .evaluate()
        .toList()
      ..sort((a, b) => (a.renderObject! as RenderBox)
          .localToGlobal(Offset.zero)
          .dy
          .compareTo((b.renderObject! as RenderBox).localToGlobal(Offset.zero).dy));
    return [for (final e in els) ((e.widget.key!) as ValueKey<String>).value];
  }

  /// The repeat window is on the wall clock.
  Future<void> waitRepeat(WidgetTester tester) =>
      tester.runAsync(() => Future<void>.delayed(phraseRepeatWindow + const Duration(milliseconds: 50)));

  int indexOfText(String text) => s.quick.phrases.indexWhere((p) => p is Phrase && p.text == text);

  iosTest('no stars: the row is every item by count, then list order; 命令▾ 常用语▾ at the end', (tester) async {
    final jd = indexOfText('进度'), compact = indexOfCmd('compact');
    s.recordUse(refOf(s.quick.phrases[jd]));
    s.recordUse(refOf(s.quick.phrases[jd]));
    s.recordUse(refOf(s.quick.phrases[compact]));
    await tester.pumpWidget(strip(tsess));
    final keys = rowKeys(tester);
    expect(keys, expectedKeys(tool: true));
    expect(keys.take(3), ['phrase-$jd', 'phrase-$compact', 'phrase-0']);
    expect(keys, hasLength(s.quick.phrases.length));
    expect(ph('quick-menu-keys'), findsNothing, reason: 'the 按键动作 are gone');
    expect(find.text('按键▾'), findsNothing);
    expect(ph('phrases-all'), findsNothing);
    expect(find.descendant(of: ph('quick-menu-cmds'), matching: find.text('命令▾')), findsOneWidget);
    expect(find.descendant(of: ph('quick-menu-phrases'), matching: find.text('常用语▾')), findsOneWidget);
    // Pinned at the right end, as high as a chip, 命令▾ before 常用语▾.
    final list = tester.getRect(ph('phrase-strip-list'));
    final cr = tester.getRect(ph('quick-menu-cmds')), pr = tester.getRect(ph('quick-menu-phrases'));
    expect(cr.left, greaterThanOrEqualTo(list.right));
    expect(pr.left, greaterThan(cr.left));
    expect(cr.height, phraseStripChip);
    expect(pr.height, phraseStripChip);
  });

  iosTest('命令▾ lists the commands only, 搜历史 among them; 常用语▾ the phrases only; both in list order', (tester) async {
    await tester.pumpWidget(strip(tsess));
    final q = s.quick;
    await tester.tap(ph('quick-menu-cmds'));
    await tester.pumpAndSettle();
    expect(find.text('命令'), findsOneWidget, reason: 'the sheet title');
    expect(sheetRows(tester), [
      for (final (i, it) in q.phrases.indexed)
        if (it is StripCmd) 'menu-p-$i',
    ]);
    expect(find.descendant(of: ph('menu-p-${indexOfCmd('search')}'), matching: find.text('搜历史')), findsOneWidget);
    Navigator.of(tester.element(ph('menu-settings'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(ph('quick-menu-phrases'));
    await tester.pumpAndSettle();
    expect(sheetRows(tester), [
      for (final (i, it) in q.phrases.indexed)
        if (it is Phrase) 'menu-p-$i',
    ]);
  });

  iosTest('starring in a menu: row shows only the starred, sheet stays, nothing sent', (tester) async {
    await tester.pumpWidget(strip(tsess));
    final i = indexOfText('进度');
    term.calls.clear();
    await tester.tap(ph('quick-menu-phrases'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: ph('menu-star-p-$i'), matching: find.byIcon(Icons.star_border)), findsOneWidget);
    // The one star of 快捷区, the same as on the settings pages.
    expect(tester.widget(ph('menu-star-p-$i')), isA<StarButton>());
    expect(find.descendant(of: ph('menu-star-p-$i'), matching: find.byTooltip('打星')), findsOneWidget);
    await tester.tap(ph('menu-star-p-$i'));
    await tester.pumpAndSettle();
    expect(ph('menu-settings'), findsOneWidget, reason: 'the sheet stays');
    expect(find.descendant(of: ph('menu-star-p-$i'), matching: find.byIcon(Icons.star)), findsOneWidget);
    expect(s.quick.stars, [refOf(s.quick.phrases[i])]);
    expect(term.calls.where((c) => c.$1 != 'composer'), isEmpty);
    Navigator.of(tester.element(ph('menu-settings'))).pop();
    await tester.pumpAndSettle();
    expect(rowKeys(tester), ['phrase-$i']);
    // A star on a command too, in star order.
    final se = indexOfCmd('search');
    await tester.tap(ph('quick-menu-cmds'));
    await tester.pumpAndSettle();
    expect(tester.widget(ph('menu-star-p-$se')), isA<StarButton>());
    await tester.tap(ph('menu-star-p-$se'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(ph('menu-settings'))).pop();
    await tester.pumpAndSettle();
    expect(rowKeys(tester), ['phrase-$i', 'phrase-$se']);
    expect(term.calls.where((c) => c.$1 != 'composer'), isEmpty);
  });

  iosTest('tapping a menu row sends and closes; grey row explains and stays', (tester) async {
    fg('agy');
    await tester.pumpWidget(strip(tsess));
    final se = indexOfCmd('search'), mode = indexOfCmd('mode');
    expect(find.ancestor(of: ph('phrase-$se'), matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1)),
        findsOneWidget, reason: 'Antigravity has no 搜历史: grey on the row');
    await tester.tap(ph('quick-menu-cmds'));
    await tester.pumpAndSettle();
    expect(find.ancestor(of: ph('menu-p-$se'), matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1)),
        findsOneWidget);
    await tester.tap(ph('menu-p-$se'));
    await tester.pumpAndSettle();
    expect(ph('menu-settings'), findsOneWidget, reason: 'a grey row keeps the sheet');
    expect(tester.widget<Text>(ph('menu-hint')).data, 'Antigravity 没有这个命令');
    expect(term.calls.where((c) => c.$1 == 'keys'), isEmpty);
    // Its star still works.
    await tester.tap(ph('menu-star-p-$se'));
    await tester.pumpAndSettle();
    expect(s.quick.stars, [refOf(s.quick.phrases[se])]);
    await tester.tap(ph('menu-p-$mode'));
    await tester.pumpAndSettle();
    expect(ph('menu-settings'), findsNothing, reason: 'sent: the sheet closes');
    expect(term.calls.where((c) => c.$1 == 'keys'), hasLength(1));
    expect(usageTotals([s.quick.usage], DateTime.now())['p:mode'], 1);
    await waitRepeat(tester);
    // A phrase from 常用语▾ goes the same way.
    await tester.tap(ph('quick-menu-phrases'));
    await tester.pumpAndSettle();
    final i = indexOfText('继续');
    await tester.tap(ph('menu-p-$i'));
    await tester.pumpAndSettle();
    expect(ph('menu-settings'), findsNothing);
    expect(usageTotals([s.quick.usage], DateTime.now())[refOf(s.quick.phrases[i])], 1);
    await waitRepeat(tester);
  });

  iosTest('设置… opens the right page', (tester) async {
    await tester.pumpWidget(strip(tsess));
    await tester.tap(ph('quick-menu-phrases'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: ph('menu-settings'), matching: find.text('设置…')), findsOneWidget);
    await tester.tap(ph('menu-settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PhrasesPage), findsOneWidget);
    expect(find.byType(CmdsPage), findsNothing);
    Navigator.of(tester.element(find.byType(PhrasesPage))).pop();
    await tester.pumpAndSettle();
    await tester.tap(ph('quick-menu-cmds'));
    await tester.pumpAndSettle();
    await tester.tap(ph('menu-settings'));
    await tester.pumpAndSettle();
    expect(find.byType(CmdsPage), findsOneWidget);
    expect(find.byType(PhrasesPage), findsNothing);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('命令')), findsOneWidget);
  });

  iosTest('the order does not change while in use, but does when stars change', (tester) async {
    s.setStripItems([const Phrase('甲'), const Phrase('乙'), const StripCmd('search')]);
    await tester.pumpWidget(strip(tsess));
    final before = rowKeys(tester);
    expect(before, ['phrase-0', 'phrase-1', 'phrase-2']);
    for (var n = 0; n < 3; n++) {
      await tester.tap(ph('phrase-2'));
      await tester.pump();
      await waitRepeat(tester);
    }
    expect(usageTotals([s.quick.usage], DateTime.now())['p:search'], 3);
    expect(term.calls.where((c) => c.$1 == 'keys'), hasLength(3), reason: '搜历史 is ⌃R on Claude Code');
    expect(rowKeys(tester), before, reason: 'counts alone do not reorder');
    s.toggleStar(refOf(s.quick.phrases[1]));
    await tester.pump();
    expect(rowKeys(tester), ['phrase-1']);
    s.toggleStar(refOf(s.quick.phrases[1]));
    await tester.pump();
    expect(rowKeys(tester).first, 'phrase-2', reason: 'stars changed: counted again');
  });

  iosTest('the row shows with only the two menus when nothing fits', (tester) async {
    app.setProfile(const ResolvedProfile(phrases: true));
    s.setStripItems([const StripCmd('new')]); // a command, and no tool in front of an app
    expect(phraseStripShown(s, app), isTrue);
    await tester.pumpWidget(strip(app));
    expect(rowKeys(tester), isEmpty);
    expect(ph('quick-menu-cmds'), findsOneWidget);
    expect(ph('quick-menu-phrases'), findsOneWidget);
  });

  iosTest('long press: 打星 / 取消星标, and 移到最前 only on a starred item', (tester) async {
    await tester.pumpWidget(strip(tsess));
    final i = indexOfText('进度'), j = indexOfText('继续');
    await tester.longPress(ph('phrase-$i'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: ph('phrase-menu-star'), matching: find.text('打星')), findsOneWidget);
    expect(ph('phrase-menu-first'), findsNothing);
    await tester.tap(ph('phrase-menu-star'));
    await tester.pumpAndSettle();
    final ri = refOf(s.quick.phrases[i]), rj = refOf(s.quick.phrases[j]);
    expect(s.quick.stars, [ri]);
    s.toggleStar(rj);
    await tester.pump();
    expect(rowKeys(tester), ['phrase-$i', 'phrase-$j']);
    await tester.longPress(ph('phrase-$j'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: ph('phrase-menu-star'), matching: find.text('取消星标')), findsOneWidget);
    await tester.tap(ph('phrase-menu-first'));
    await tester.pumpAndSettle();
    expect(s.quick.stars, [rj, ri]);
    expect(rowKeys(tester), ['phrase-$j', 'phrase-$i']);
    await tester.longPress(ph('phrase-$i'));
    await tester.pumpAndSettle();
    await tester.tap(ph('phrase-menu-star'));
    await tester.pumpAndSettle();
    expect(s.quick.stars, [rj]);
  });

  iosTest('no AI tool: the commands stay in 命令▾, grey; a tap sends nothing, the star still works', (tester) async {
    fg('zsh', shell: true);
    await tester.pumpWidget(strip(tsess));
    final i = s.quick.phrases.indexWhere((it) => it is StripCmd && it.id == 'new');
    final ref = refOf(s.quick.phrases[i]);
    expect(ph('phrase-$i'), findsNothing, reason: 'not on the row (spec §5.2)');
    term.calls.clear();
    await tester.tap(ph('quick-menu-cmds'));
    await tester.pumpAndSettle();
    expect(ph('menu-p-$i'), findsOneWidget);
    expect(find.ancestor(of: ph('menu-p-$i'), matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1)),
        findsOneWidget);
    await tester.tap(ph('menu-p-$i'));
    await tester.pumpAndSettle();
    expect(ph('menu-settings'), findsOneWidget, reason: 'a grey row keeps the sheet');
    expect(tester.widget<Text>(ph('menu-hint')).data, '这里没有认得的 AI 工具，发不了命令');
    expect(term.calls.where((c) => c.$1 != 'composer'), isEmpty);
    expect(usageTotals([s.quick.usage], DateTime.now())[ref], isNull);
    await tester.tap(ph('menu-star-p-$i'));
    await tester.pumpAndSettle();
    expect(s.quick.stars, [ref]);
    expect(ph('menu-settings'), findsOneWidget);
    expect(term.calls.where((c) => c.$1 != 'composer'), isEmpty);
  });

  testWidgets('Linux desktop: mouse click on a quick-row key action sends keys while preserving editor focus and IME preedit',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tsess.composer.open = true;
    s.toggleStar('k:clear');
    await tester.pumpWidget(wrap(SizedBox(
      width: 1200,
      height: 700,
      child: Stack(children: composerLayer(state: s, session: tsess, port: term, editor: FlutterEditor.new)),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('bar-stab')), findsNothing);
    expect(ph('quick-menu-keys'), findsOneWidget);
    expect(ph('quick-menu-phrases'), findsOneWidget);

    final field = find.byKey(const Key('composer-field'));
    await tester.tap(field, kind: PointerDeviceKind.mouse);
    await tester.pump();
    EditableText editor() => tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)));
    const preedit = TextEditingValue(
      text: 'hello ni',
      selection: TextSelection.collapsed(offset: 8),
      composing: TextRange(start: 6, end: 8),
    );
    tester.testTextInput.updateEditingValue(preedit);
    await tester.pump();

    term.calls.clear();
    await tester.tap(ph('keyact-clear'), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(term.calls.where((c) => c.$1 == 'keys').single.$2['keys'], ['Ctrl-L']);
    expect(editor().focusNode.hasFocus, isTrue);
    expect(editor().controller.value, preedit);
    await waitRepeat(tester);
    await tester.pump(const Duration(seconds: 2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
