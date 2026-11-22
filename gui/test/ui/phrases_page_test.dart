import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/phrases_page.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late Directory tmp;
  late MainState s;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('phrases_page_test');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort());
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

  List<String> texts() => [for (final p in s.prefs.phrases) p.text];

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
    expect(s.prefs.phrases.last, const Phrase('帮我看看日志', put: true));
    expect(s.prefs.phrases, hasLength(defaultPhrases.length + 1));
  });

  testWidgets('tap a row edits it; swipe deletes; 恢复默认 brings the ten back', (tester) async {
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
    expect(texts(), hasLength(defaultPhrases.length - 1));

    await tester.tap(find.byKey(const Key('phrase-reset')));
    await tester.pumpAndSettle();
    expect(s.prefs.phrases, defaultPhrases);
  });
}
