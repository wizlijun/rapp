// The 整理 card on the stage (plan 2026-11-20-rapp-voice-ai-tidy Task 5).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/tidy_diff.dart';
import 'package:rapp/embed/tidy_mode.dart';
import 'package:rapp/embed/voice_tidy.dart';
import 'package:rapp/embed/voice_tidy_card.dart';
import 'package:rapp/embed/stage_buttons.dart' show stageButtonsIn;
import 'package:rapp/embed/voice_ring.dart' show VoicePick;
import 'package:rapp/hub_client.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';
import 'voice_button_test.dart' show FakeVoice;

class _FakeApi extends LlmApi {
  final calls = <LlmCall>[];
  void Function(String)? onText;

  @override
  LlmCall run(LlmEndpoint e, String app, String input,
      {Map<String, String>? vars, void Function(String text)? onText, Duration firstByte = const Duration(seconds: 10), bool think = false}) {
    this.onText = onText;
    final c = LlmCall.manual();
    calls.add(c);
    return c;
  }
}

const long = '嗯那个我门明天下午三点开会';

void main() {
  late FakeTransport t;
  late FakeSessionPort port;
  late MainState es;
  late Directory tmp;
  late _FakeApi api;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('voice_tidy_card_test');
    t = FakeTransport();
    final hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    port = FakeSessionPort();
    api = _FakeApi();
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, voice: FakeVoice(), llmApi: api);
    es.setLlm(const LlmEndpoint(url: 'localhost:28001', key: 'k'));
  });

  tearDown(() {
    es.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<RemoteSession> goLive(WidgetTester tester) async {
    await tester.runAsync(() async {
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          t.emit({
            'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            'port': 5001, 'token': 'tk', 'req': m['req'],
          });
        }
      };
      es.openOrSwitch('111', 'Safari', 'Safari');
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    return es.remote[1]!;
  }

  Widget layer(RemoteSession s) => wrap(SizedBox(
      key: const Key('stage'),
      width: 1000,
      height: 700,
      child: Stack(children: composerLayer(state: es, session: s, port: port, editor: FlutterEditor.new))));

  void macTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          tester.view.physicalSize = const Size(1200, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await body(tester);
          // The tidy's 30 s cap must not outlive the test.
          es.tidyIfAny(1)?.closed();
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

  List<Object?> sends() => [for (final c in port.calls) if (c.$1 == 'composer_send') c.$2['pieces']];
  final card = find.byKey(const Key('tidy-card'));
  String text(String key) {
    final w = find.byKey(Key(key)).evaluate().single.widget as Text;
    return w.data ?? w.textSpan?.toPlainText() ?? '';
  }
  bool filled(WidgetTester tester, String key) =>
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(FilledButton)).evaluate().isNotEmpty;

  macTest('the title shows 对人 ⇄ and a tap switches', (tester) async {
    final s = await goLive(tester);
    es.prefs.voiceTidyMode['Safari'] = TidyMode.chat;
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send);
    await tester.pump();
    expect(text('tidy-mode'), '· 对人 ⇄');
    await tester.tap(find.byKey(const Key('tidy-mode')));
    await tester.pump();
    expect(text('tidy-mode'), '· 提示词 ⇄');
    expect(es.prefs.voiceTidyMode['Safari'], TidyMode.prompt);
    expect(api.calls, hasLength(2));
  });

  macTest('while comparing there is no tappable ⇄', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send);
    await tester.pump();
    expect(find.byKey(const Key('tidy-mode')), findsOneWidget);
    es.tidyOf(1).compare();
    await tester.pump();
    expect(find.byKey(const Key('tidy-mode')), findsNothing);
  });

  macTest('the card shows while tidying and its buttons act', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    expect(card, findsNothing);
    expect(es.tidyOf(1).begin(long, VoicePick.send), isTrue);
    await tester.pump();
    expect(card, findsOneWidget);
    expect(text('tidy-title'), 'AI 整理中…');
    expect(find.byKey(const Key('tidy-body')), findsOneWidget);
    expect(filled(tester, 'tidy-send'), isTrue);
    expect(filled(tester, 'tidy-edit'), isFalse);
    await tester.tap(find.byKey(const Key('tidy-send')));
    await tester.pumpAndSettle();
    expect(sends(), [
      [
        {'text': long}
      ]
    ]);
    expect(card, findsNothing);
  });

  macTest('a failure takes the card away and sends the original', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send);
    await tester.pump();
    expect(card, findsOneWidget);
    api.calls.single.complete(const LlmFailed('连不上 LLM 接入点'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(find.textContaining('失败'), findsNothing);
    expect(sends(), [
      [
        {'text': long}
      ]
    ]);
  });

  macTest('还原 shows once the AI is done and sends the original', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send);
    await tester.pump();
    expect(find.byKey(const Key('tidy-restore')), findsNothing);
    api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('tidy-restore')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tidy-restore')));
    await tester.pumpAndSettle();
    expect(sends(), [
      [
        {'text': long}
      ]
    ]);
    expect(card, findsNothing);
  });

  macTest('before the first word a shimmer runs over the original; then a caret follows the AI words',
      (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    final t = es.tidyOf(1);
    t.begin(long, VoicePick.send);
    await tester.pump();
    expect(find.byKey(const Key('tidy-shimmer')), findsOneWidget);
    expect(find.byKey(const Key('tidy-caret')), findsNothing);
    expect(text('tidy-body'), contains(long));
    api.onText!('我们明天');
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const Key('tidy-shimmer')), findsNothing);
    expect(find.byKey(const Key('tidy-caret')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2)); // it blinks, and does not stop the test
    api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('tidy-caret')), findsNothing);
  });

  macTest('done while its last words are still coming out: still writing, the send waits', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send);
    api.calls.single.complete(const LlmDone('我们明天下午三点开会，把上周的数据带上。'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(text('tidy-title'), 'AI 整理中…');
    expect(find.byKey(const Key('tidy-caret')), findsOneWidget);
    expect(find.byKey(const Key('tidy-drain')), findsNothing);
    expect(text('tidy-body'), isNot(contains('带上')));
    await tester.pump(const Duration(milliseconds: 700));
    expect(text('tidy-title'), '整理好了，马上发送');
    expect(text('tidy-body'), '我们明天下午三点开会，把上周的数据带上。');
    expect(find.byKey(const Key('tidy-drain')), findsOneWidget);
    expect(sends(), isEmpty);
  });

  macTest('the original stays under the AI words in one line; a tap opens it and holds the send', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send);
    await tester.pump();
    // Before the first word the original is the body itself: no second copy.
    expect(find.byKey(const Key('tidy-original')), findsNothing);
    api.onText!('我们明天');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(text('tidy-body'), startsWith('我们明天'));
    expect(text('tidy-body'), isNot(contains('下午')));
    final line = tester.widget<Text>(find.byKey(const Key('tidy-original')));
    expect(text('tidy-original'), contains(long));
    expect(line.maxLines, 1);
    api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(text('tidy-original'), contains(long));
    await tester.tap(find.byKey(const Key('tidy-original')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('tidy-original'))).maxLines, greaterThan(1));
    expect(find.byKey(const Key('tidy-drain')), findsNothing);
    expect(text('tidy-title'), '整理好了');
    await tester.pump(const Duration(seconds: 5));
    expect(sends(), isEmpty);
    await tester.tap(find.byKey(const Key('tidy-send')));
    await tester.pumpAndSettle();
    expect(sends(), [
      [
        {'text': '我们明天下午三点开会。'}
      ]
    ]);
  });

  macTest('stage buttons stay usable under the card', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send);
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-open')));
    // Not pumpAndSettle: the shimmer runs until the first word.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(s.composer.open, isTrue);
    expect(card, findsOneWidget);
  });

  macTest('the card shows with the panel open', (tester) async {
    final s = await goLive(tester);
    s.composer.open = true;
    await tester.pumpWidget(layer(s));
    await tester.pumpAndSettle();
    es.tidyOf(1).begin(long, VoicePick.send);
    await tester.pump();
    await tester.pump();
    expect(card, findsOneWidget);
    // Above the panel, right-aligned with it (spec §5.3).
    final panel = tester.getRect(find.byType(ComposerPanel));
    final r = tester.getRect(card);
    expect(r.bottom, lessThanOrEqualTo(panel.top - 8 + 0.5));
    expect(r.right, closeTo(panel.right, 1));
  });

  testWidgets('on iOS the card stands above the stage buttons', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await goLive(tester);
      await tester.pumpWidget(layer(s));
      es.tidyOf(1).begin(long, VoicePick.send);
      await tester.pump();
      final r = tester.getRect(card), b = tester.getRect(find.byKey(const Key('composer-open')));
      expect(r.bottom, lessThanOrEqualTo(b.top));
      expect(r.right, closeTo(tester.getRect(find.byKey(const Key('stage'))).right - stageButtonsIn, 0.5));
      es.tidyIfAny(1)?.closed();
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  macTest('edit pick makes 编辑 primary', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.edit);
    await tester.pump();
    expect(filled(tester, 'tidy-edit'), isTrue);
    expect(filled(tester, 'tidy-send'), isFalse);
  });

  macTest('a done send shows the AI text with 编辑 and 发送, then sends and goes', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send);
    api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(text('tidy-title'), '整理好了，马上发送');
    expect(text('tidy-body'), '我们明天下午三点开会。');
    expect(find.descendant(of: find.byKey(const Key('tidy-send')), matching: find.text('发送')), findsOneWidget);
    expect(find.byKey(const Key('tidy-edit')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(sends(), [
      [
        {'text': '我们明天下午三点开会。'}
      ]
    ]);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
  });

  macTest('the card stands where the voice bubble was', (tester) async {
    final s = await goLive(tester);
    await tester.pumpWidget(layer(s));
    es.tidyOf(1).begin(long, VoicePick.send, at: const Rect.fromLTWH(300, 200, 420, 90));
    await tester.pump();
    await tester.pump();
    final r = tester.getRect(find.byKey(const Key('tidy-bubble')));
    expect(r.topLeft.dx, closeTo(300, 1));
    expect(r.topLeft.dy, closeTo(200, 1));
    expect(r.width, closeTo(420, 1));
  });

  group('marks on the AI changes, tap to flip, remember offer', () {
    const heard = '明天用拍森跑一下黑猫瑞';
    const ai = '明天用Python跑一下Hemory';
    late List<List<LearnItem>> learned;
    late VoiceTidy tidy;

    setUp(() => learned = []);

    VoiceTidy makeTidy() => tidy = VoiceTidy(
          sid: 1,
          endpoint: () => const LlmEndpoint(url: 'localhost:28001', key: 'k'),
          api: api,
          allowed: (_) => true,
          send: (sid, t, v) => null,
          edit: (sid, t, ai) {},
          keep: (sid, t) {},
          learn: (sid, items) => learned.add(items),
        );

    Widget host(VoiceTidy t, {bool reduced = false}) =>
        wrap(SizedBox(width: 360, child: VoiceTidyCard(tidy: t)), disableAnimations: reduced);

    Future<void> ready(WidgetTester tester, String h, String a, {bool reduced = false}) async {
      await tester.pumpWidget(host(makeTidy(), reduced: reduced));
      tidy.begin(h, VoicePick.send);
      api.calls.single.complete(LlmDone(a));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    void tidyTest(String name, Future<void> Function(WidgetTester) body, {TargetPlatform p = TargetPlatform.macOS}) =>
        testWidgets(name, (tester) async {
          debugDefaultTargetPlatformOverride = p;
          try {
            await body(tester);
            tidy.dispose();
            await tester.pumpWidget(const SizedBox());
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });

    List<String> dashed(WidgetTester tester) {
      final span = tester.widget<Text>(find.byKey(const Key('tidy-body'))).textSpan! as TextSpan;
      return [
        for (final c in span.children!.whereType<TextSpan>())
          if (c.style?.decorationStyle == TextDecorationStyle.dashed) c.text!,
      ];
    }

    // Where [word] is in the body, global.
    Offset centerOf(WidgetTester tester, String word) {
      RenderParagraph? para_(RenderObject r) {
        if (r is RenderParagraph) return r;
        RenderParagraph? out;
        r.visitChildren((c) => out ??= para_(c));
        return out;
      }

      final ro = tester.renderObject(find.byKey(const Key('tidy-body')));
      final para = para_(ro)!;
      final at = para.text.toPlainText().indexOf(word);
      final box = para.getBoxesForSelection(TextSelection(baseOffset: at, extentOffset: at + word.length)).first;
      return para.localToGlobal(box.toRect().center);
    }

    String body(WidgetTester tester) =>
        (tester.widget<Text>(find.byKey(const Key('tidy-body'))).textSpan! as TextSpan).toPlainText();

    tidyTest('changes are underlined dashed once the words are out', (tester) async {
      await ready(tester, heard, ai);
      expect(dashed(tester), ['Python', 'Hemory']);
      expect(find.byKey(const Key('tidy-drain')), findsOneWidget);
    });

    tidyTest('tapping a marked word flips it and the drain goes', (tester) async {
      await ready(tester, heard, ai);
      await tester.tapOnText(find.textRange.ofSubstring('Hemory'));
      await tester.pump();
      expect(body(tester), contains('黑猫瑞'));
      expect(body(tester), contains('Python'));
      expect(find.byKey(const Key('tidy-drain')), findsNothing);
      expect(text('tidy-title'), '整理好了');
      expect(dashed(tester), ['Python', '黑猫瑞']);
      await tester.tapOnText(find.textRange.ofSubstring('黑猫瑞').first);
      await tester.pump();
      expect(body(tester), ai);
    });

    tidyTest('the bubble offer reads 记住：别把「黑猫瑞」改成「Hemory」？ and 记住 shows 已记住', (tester) async {
      await ready(tester, heard, ai);
      expect(find.byKey(const Key('learn-offer')), findsNothing);
      await tester.tapOnText(find.textRange.ofSubstring('Hemory'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('learn-offer')), findsOneWidget);
      expect(find.text('记住：别把「黑猫瑞」改成「Hemory」？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('learn-remember')));
      await tester.pump();
      expect(learned.single.single, LearnItem.preserve(observed: '黑猫瑞', avoid: 'Hemory', excerpt: heard));
      expect(find.byKey(const Key('learn-done')), findsOneWidget);
      expect(find.text('已记住'), findsOneWidget);
    });

    tidyTest('忽略 takes the bubble offer away', (tester) async {
      await ready(tester, heard, ai);
      await tester.tapOnText(find.textRange.ofSubstring('Hemory'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('learn-ignore')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('learn-offer')), findsNothing);
      expect(learned, isEmpty);
    });

    tidyTest('the 8 s box lists items with checkboxes and stands without a tidy', (tester) async {
      await tester.pumpWidget(host(makeTidy()));
      expect(tidy.phase, TidyPhase.idle);
      tidy.offerLearn(const [
        LearnItem.replace(observed: '拍森', output: 'Python', excerpt: 'x'),
        LearnItem.replace(observed: '黑猫瑞', output: 'Hemory', excerpt: 'x'),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('learn-offer')), findsOneWidget);
      expect(find.text('记住这个改法？'), findsOneWidget);
      expect(find.text('拍森 → Python'), findsOneWidget);
      for (final i in [0, 1]) {
        expect(tester.widget<Checkbox>(find.byKey(Key('learn-item-$i'))).value, isTrue);
      }
      await tester.tap(find.byKey(const Key('learn-item-1')));
      await tester.pump();
      expect(tester.widget<Checkbox>(find.byKey(const Key('learn-item-1'))).value, isFalse);
      await tester.tap(find.byKey(const Key('learn-remember')));
      await tester.pump();
      expect(learned.single.map((e) => e.observed), ['拍森']);
      expect(find.byKey(const Key('learn-done')), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(find.byKey(const Key('learn-offer')), findsNothing);
    });

    tidyTest('the box goes above a card that is showing', (tester) async {
      await ready(tester, heard, ai);
      tidy.offerLearn(const [LearnItem.replace(observed: '拍森', output: 'Python', excerpt: 'x')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(find.byKey(const Key('learn-offer'))).bottom,
          lessThanOrEqualTo(tester.getRect(find.byKey(const Key('tidy-card'))).top));
    });

    tidyTest('a change cut off by the 4-line tail is not marked', (tester) async {
      final fill = '今天天气很好我们一起去公园玩' * 8;
      await ready(tester, '拍森$fill黑猫瑞', 'Python$fill' 'Hemory');
      expect(tester.widget<Text>(find.byKey(const Key('tidy-body'))).textSpan!.toPlainText(), startsWith('…'));
      expect(dashed(tester), ['Hemory']);
    });

    tidyTest('on iOS a tap 15 px above a marked word still flips it', (tester) async {
      await ready(tester, heard, ai);
      final c = centerOf(tester, 'Hemory');
      await tester.tapAt(c - const Offset(0, 15));
      await tester.pump();
      expect(tidy.flipped(1), isTrue);
      // Far above is not a tap on the word.
      await tester.tapAt(c - const Offset(0, 60));
      await tester.pump();
      expect(tidy.flipped(0), isFalse);
    }, p: TargetPlatform.iOS);

    tidyTest('on the desktop a tap 15 px above a marked word does not flip it', (tester) async {
      await ready(tester, heard, ai);
      final c = centerOf(tester, 'Hemory');
      await tester.tapAt(c - const Offset(0, 15));
      await tester.pump();
      expect(tidy.flipped(1), isFalse);
    });

    tidyTest('with reduced motion the offer appears without animation', (tester) async {
      await ready(tester, heard, ai, reduced: true);
      await tester.tapOnText(find.textRange.ofSubstring('Hemory'));
      await tester.pump();
      expect(find.byKey(const Key('learn-offer')), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    tidyTest('the card keeps its state while the box comes and goes', (tester) async {
      await ready(tester, heard, ai);
      final drain = tester.state(find.byType(TweenAnimationBuilder<double>).evaluate().isNotEmpty
          ? find.descendant(of: find.byKey(const Key('tidy-card')), matching: find.byType(TweenAnimationBuilder<double>)).first
          : find.byKey(const Key('tidy-drain')));
      tidy.offerLearn(const [LearnItem.replace(observed: '拍森', output: 'Python', excerpt: 'x')]);
      await tester.pump();
      expect(find.byKey(const Key('learn-offer')), findsOneWidget);
      expect(find.byKey(const Key('tidy-drain')), findsOneWidget);
      expect(tester.state(find.descendant(of: find.byKey(const Key('tidy-card')), matching: find.byType(TweenAnimationBuilder<double>)).first), same(drain));
      tidy.dismissOffer();
      await tester.pump();
      expect(find.byKey(const Key('learn-offer')), findsNothing);
      expect(tester.state(find.descendant(of: find.byKey(const Key('tidy-card')), matching: find.byType(TweenAnimationBuilder<double>)).first), same(drain));
    });

    tidyTest('flipping change 0 first leaves change 1 marked on exactly its own text', (tester) async {
      await ready(tester, heard, ai);
      await tester.tapOnText(find.textRange.ofSubstring('Python').first);
      await tester.pump();
      expect(body(tester), '明天用拍森跑一下Hemory');
      expect(dashed(tester), ['拍森', 'Hemory']);
      await tester.tapOnText(find.textRange.ofSubstring('Hemory').first);
      await tester.pump();
      expect(tidy.flipped(1), isTrue);
      expect(body(tester), heard);
      expect(dashed(tester), ['拍森', '黑猫瑞']);
    });

    tidyTest('an emoji before a change does not shift its mark', (tester) async {
      await ready(tester, '😀明天用拍森跑一下黑猫瑞', '😀明天用Python跑一下Hemory');
      expect(dashed(tester), ['Python', 'Hemory']);
      await tester.tapOnText(find.textRange.ofSubstring('Hemory').first);
      await tester.pump();
      expect(tidy.flipped(1), isTrue);
      expect(dashed(tester), ['Python', '黑猫瑞']);
    });

    tidyTest('with motion the offer fades in', (tester) async {
      await ready(tester, heard, ai);
      await tester.tapOnText(find.textRange.ofSubstring('Hemory'));
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
    });
  });
}
