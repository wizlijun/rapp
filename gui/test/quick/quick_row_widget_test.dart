// The 快捷区 first row (quick-row spec §5): the chips in front (the starred, or every item by use count), and the two
// menus 「按键▾」「常用语▾」 pinned at its right end.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/phrase_send.dart';
import 'package:rapp/embed/phrase_strip.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/keys_page.dart';
import 'package:rapp/pages/phrases_page.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/quick_row.dart';
import 'package:rapp/quick/quick_usage.dart';
import 'package:rapp/term/term_session_port.dart';
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
            (k.value.startsWith('phrase-') || k.value.startsWith('keyact-'));
      }),
    );
    final els = f.evaluate().toList()
      ..sort((a, b) => (a.renderObject! as RenderBox)
          .localToGlobal(Offset.zero)
          .dx
          .compareTo((b.renderObject! as RenderBox).localToGlobal(Offset.zero).dx));
    return [for (final e in els) ((e.widget.key!) as ValueKey<String>).value];
  }

  /// quickRowOrder's answer for the state now, as chip keys (commands only with a tool, key actions only usable ones).
  List<String> expectedKeys({required bool term, required bool tool}) {
    final q = s.quick;
    final order = quickRowOrder(
      phraseRefs: [for (final p in q.phrases) refOf(p)],
      keyRefs: [for (final a in q.keys) a.ref],
      stars: q.stars,
      totals: usageTotals([q.usage, ...q.others.values], DateTime.now()),
    );
    final out = <String>[];
    for (final r in order) {
      final i = q.phrases.indexWhere((it) => refOf(it) == r);
      if (i >= 0) {
        if (q.phrases[i] is Phrase || tool) out.add('phrase-$i');
        continue;
      }
      for (final a in q.keys) {
        if (a.ref == r && keyActionUsable(a, term: term, tool: tool ? s.stripToolOf(tsess) : null)) out.add('keyact-${a.id}');
      }
    }
    return out;
  }

  /// The repeat window is on the wall clock.
  Future<void> waitRepeat(WidgetTester tester) =>
      tester.runAsync(() => Future<void>.delayed(phraseRepeatWindow + const Duration(milliseconds: 50)));

  int indexOfText(String text) => s.quick.phrases.indexWhere((p) => p is Phrase && p.text == text);

  iosTest('no stars: the row is phrases by count then key actions; menus at the end', (tester) async {
    s.recordUse('k:clear');
    s.recordUse('k:clear');
    s.recordUse(refOf(s.quick.phrases[indexOfText('进度')]));
    await tester.pumpWidget(strip(tsess));
    final keys = rowKeys(tester);
    expect(keys, expectedKeys(term: true, tool: true));
    expect(keys.first, 'keyact-clear');
    expect(keys[1], 'phrase-${indexOfText('进度')}');
    // The rest by menu order: the commands, the phrases, then the key actions.
    expect(keys[2], 'phrase-0');
    expect(keys.last, 'keyact-newtab');
    expect(ph('quick-menu-keys'), findsOneWidget);
    expect(ph('quick-menu-phrases'), findsOneWidget);
    expect(ph('phrases-all'), findsNothing);
    expect(find.descendant(of: ph('quick-menu-keys'), matching: find.text('按键▾')), findsOneWidget);
    expect(find.descendant(of: ph('quick-menu-phrases'), matching: find.text('常用语▾')), findsOneWidget);
    // Pinned at the right end, as high as a chip, 按键▾ before 常用语▾.
    final list = tester.getRect(ph('phrase-strip-list'));
    final kr = tester.getRect(ph('quick-menu-keys')), pr = tester.getRect(ph('quick-menu-phrases'));
    expect(kr.left, greaterThanOrEqualTo(list.right));
    expect(pr.left, greaterThan(kr.left));
    expect(kr.height, phraseStripChip);
    expect(pr.height, phraseStripChip);
  });

  iosTest('starring in a menu: row shows only the starred, sheet stays, nothing sent', (tester) async {
    await tester.pumpWidget(strip(tsess));
    final i = indexOfText('进度');
    term.calls.clear();
    await tester.tap(ph('quick-menu-phrases'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: ph('menu-star-p-$i'), matching: find.byIcon(Icons.star_border)), findsOneWidget);
    await tester.tap(ph('menu-star-p-$i'));
    await tester.pumpAndSettle();
    expect(ph('menu-settings'), findsOneWidget, reason: 'the sheet stays');
    expect(find.descendant(of: ph('menu-star-p-$i'), matching: find.byIcon(Icons.star)), findsOneWidget);
    expect(s.quick.stars, [refOf(s.quick.phrases[i])]);
    expect(term.calls.where((c) => c.$1 != 'composer'), isEmpty);
    Navigator.of(tester.element(ph('menu-settings'))).pop();
    await tester.pumpAndSettle();
    expect(rowKeys(tester), ['phrase-$i']);
    // A star on a key action too, in star order.
    await tester.tap(ph('quick-menu-keys'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: ph('menu-k-search'), matching: find.text('⌃R')), findsOneWidget);
    await tester.tap(ph('menu-star-k-search'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(ph('menu-settings'))).pop();
    await tester.pumpAndSettle();
    expect(rowKeys(tester), ['phrase-$i', 'keyact-search']);
    expect(term.calls.where((c) => c.$1 != 'composer'), isEmpty);
  });

  iosTest('tapping a menu row sends and closes; grey row explains and stays', (tester) async {
    fg('agy');
    await tester.pumpWidget(strip(tsess));
    expect(ph('keyact-search'), findsNothing, reason: 'grey key actions are not on the row');
    await tester.tap(ph('quick-menu-keys'));
    await tester.pumpAndSettle();
    expect(find.ancestor(of: ph('menu-k-search'), matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1)),
        findsOneWidget);
    await tester.tap(ph('menu-k-search'));
    await tester.pumpAndSettle();
    expect(ph('menu-settings'), findsOneWidget, reason: 'a grey row keeps the sheet');
    expect(tester.widget<Text>(ph('menu-hint')).data, 'Antigravity 没有这个命令');
    expect(term.calls.where((c) => c.$1 == 'keys'), isEmpty);
    // Its star still works.
    await tester.tap(ph('menu-star-k-search'));
    await tester.pumpAndSettle();
    expect(s.quick.stars, ['k:search']);
    await tester.tap(ph('menu-k-clear'));
    await tester.pumpAndSettle();
    expect(ph('menu-settings'), findsNothing, reason: 'sent: the sheet closes');
    expect(term.calls.where((c) => c.$1 == 'keys').last.$2['keys'], ['Ctrl-L']);
    expect(usageTotals([s.quick.usage], DateTime.now())['k:clear'], 1);
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
    expect(find.byType(KeysPage), findsNothing);
    Navigator.of(tester.element(find.byType(PhrasesPage))).pop();
    await tester.pumpAndSettle();
    await tester.tap(ph('quick-menu-keys'));
    await tester.pumpAndSettle();
    await tester.tap(ph('menu-settings'));
    await tester.pumpAndSettle();
    expect(find.byType(KeysPage), findsOneWidget);
    expect(find.byType(PhrasesPage), findsNothing);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('按键')), findsOneWidget);
  });

  iosTest('the order does not change while in use, but does when stars change', (tester) async {
    fg('zsh', shell: true);
    s.setStripItems([const Phrase('甲'), const Phrase('乙')]);
    await tester.pumpWidget(strip(tsess));
    final before = rowKeys(tester);
    expect(before.take(3), ['phrase-0', 'phrase-1', 'keyact-search']);
    for (var n = 0; n < 3; n++) {
      await tester.tap(ph(before[2]));
      await tester.pump();
      await waitRepeat(tester);
    }
    expect(usageTotals([s.quick.usage], DateTime.now())['k:search'], 3);
    expect(term.calls.where((c) => c.$1 == 'keys'), hasLength(3));
    expect(rowKeys(tester), before, reason: 'counts alone do not reorder');
    s.toggleStar(refOf(s.quick.phrases[1]));
    await tester.pump();
    expect(rowKeys(tester), ['phrase-1']);
    s.toggleStar(refOf(s.quick.phrases[1]));
    await tester.pump();
    expect(rowKeys(tester).first, 'keyact-search', reason: 'stars changed: counted again');
  });

  iosTest('the row shows with only the two menus when nothing fits', (tester) async {
    app.setProfile(const ResolvedProfile(phrases: true));
    s.setStripItems([const StripCmd('new')]); // a command, and no tool in front of an app
    s.setKeyActions(const []);
    expect(phraseStripShown(s, app), isTrue);
    await tester.pumpWidget(strip(app));
    expect(rowKeys(tester), isEmpty);
    expect(ph('quick-menu-keys'), findsOneWidget);
    expect(ph('quick-menu-phrases'), findsOneWidget);
  });

  iosTest('key action chip on a terminal sends its keys and counts a use', (tester) async {
    await tester.pumpWidget(strip(tsess));
    expect(term, isA<TermSessionPort>());
    await tester.tap(ph('keyact-clear'));
    await tester.pump();
    expect(term.calls.where((c) => c.$1 == 'keys').single.$2['keys'], ['Ctrl-L']);
    expect(find.descendant(of: ph('keyact-clear'), matching: find.byIcon(Icons.check)), findsOneWidget);
    expect(usageTotals([s.quick.usage], DateTime.now())['k:clear'], 1);
    await waitRepeat(tester);
    // ⌘T goes through the stage's own shortcut.
    final ran = <String>[];
    tsess.termCommand = ran.add;
    await tester.tap(ph('keyact-newtab'));
    await tester.pump();
    expect(ran, ['t']);
    expect(usageTotals([s.quick.usage], DateTime.now())['k:newtab'], 1);
    await waitRepeat(tester);
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
    // A key action: 编辑 / 打星 / 删除.
    s.toggleStar(rj);
    await tester.pump();
    await tester.longPress(ph('keyact-bg'));
    await tester.pumpAndSettle();
    expect(ph('keyact-menu-edit'), findsOneWidget);
    expect(ph('keyact-menu-delete'), findsOneWidget);
    expect(ph('phrase-menu-first'), findsNothing);
    expect(find.descendant(of: ph('phrase-menu-star'), matching: find.text('打星')), findsOneWidget);
    await tester.tap(ph('phrase-menu-star'));
    await tester.pumpAndSettle();
    expect(s.quick.stars, ['k:bg']);
    await tester.longPress(ph('keyact-bg'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: ph('phrase-menu-star'), matching: find.text('取消星标')), findsOneWidget);
    expect(ph('phrase-menu-first'), findsNothing, reason: 'a key action has no 移到最前 (spec §5.1)');
    await tester.tap(ph('keyact-menu-delete'));
    await tester.pumpAndSettle();
    expect(s.quick.keys.where((a) => a.id == 'bg'), isEmpty);
    expect(s.quick.stars, isEmpty, reason: 'the deleted action takes its star');
    expect(ph('keyact-bg'), findsNothing);
  });
}
