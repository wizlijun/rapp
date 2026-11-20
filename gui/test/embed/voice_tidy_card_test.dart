// The 整理 card on the stage (plan 2026-11-20-rapp-voice-ai-tidy Task 5).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/remote_session.dart';
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
      {Map<String, String>? vars, void Function(String text)? onText, Duration firstByte = const Duration(seconds: 10)}) {
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
    await tester.pump();
    expect(find.byKey(const Key('tidy-shimmer')), findsNothing);
    expect(find.byKey(const Key('tidy-caret')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2)); // it blinks, and does not stop the test
    api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
    await tester.pump();
    expect(find.byKey(const Key('tidy-caret')), findsNothing);
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
    await tester.pump();
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
}
