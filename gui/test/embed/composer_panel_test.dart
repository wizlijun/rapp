import 'dart:async';
import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/platform_caps.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/local_ime.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/geometry.dart';
import 'package:rapp/embed/input_dock.dart' show desktopComposerAt, dockMove;
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/modifier_latch.dart';
import 'package:rapp/embed/panel_place.dart';
import 'package:rapp/embed/picture.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/history/history_list.dart';
import 'package:rapp/embed/voice_ring.dart' show VoicePick;
import 'package:rapp/embed/voice_tidy_card.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/pages/phrases_page.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/ime_intent.dart' show ImeIntent;
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late FakeSessionPort port;
  late MainState es;
  late Directory tmp;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('composer_panel_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    port = FakeSessionPort();
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
  });

  tearDown(() {
    es.dispose();
    tmp.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> callsOf(String method) =>
      port.calls.where((c) => c.$1 == method).map((c) => c.$2).toList();

  final fieldFinder = find.byKey(const Key('composer-field'));
  TextField field(WidgetTester tester) => tester.widget<TextField>(fieldFinder);
  String text(WidgetTester tester) => field(tester).controller!.text;
  bool fieldFocused(WidgetTester tester) => field(tester).focusNode!.hasFocus;

  test('panelWidth is 720, or the stage less 16 below 736', () {
    expect(panelWidth(1200), 720);
    expect(panelWidth(736), 720);
    expect(panelWidth(700), 684);
    expect(panelWidth(1200, 1.5), 1080);
    expect(panelWidth(900, 1.5), 884); // never wider than the stage less 16
  });

  group('panel', () {
    late RemoteSession rs;

    setUp(() {
      rs = RemoteSession(1, 'Safari',
          onDropBlock: (n) => port.composerDropBlock(1, n),
          onReturn: () => port.key(1, 36, 0),
          onSelectInput: (id) => port.selectInput(1, id));
      rs.composer.open = true;
    });
    tearDown(() => rs.dispose());

    Widget panel() =>
        SizedBox(width: 720, child: ComposerPanel(state: es, session: rs, port: port, maxHeight: 300, editor: FlutterEditor.new));

    // A 1000×700 stage with the composer layer on it.
    Widget layer({RemoteSession? s, RappTheme theme = RappTheme.matrix}) => wrap(theme: theme, SizedBox(
        key: const Key('host'),
        width: 1000,
        height: 700,
        child: Stack(children: composerLayer(state: es, session: s ?? rs, port: port, editor: FlutterEditor.new))));

    void big(WidgetTester tester) {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Rect rect(WidgetTester tester, String key) => tester.getRect(find.byKey(Key(key)));

    testWidgets('caret survives shell switch', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      field(tester).controller!.value = const TextEditingValue(text: 'hello', selection: TextSelection.collapsed(offset: 2));
      await tester.pump();
      // The phone shell takes the stage's place (the composer unmounts), then the Pad comes back.
      await tester.pumpWidget(wrap(const SizedBox.shrink()));
      await tester.pump();
      await tester.pumpWidget(layer());
      await tester.pump();
      await tester.pump();
      expect(text(tester), 'hello');
      expect(field(tester).controller!.selection, const TextSelection.collapsed(offset: 2));
    });

    testWidgets('⌘= / ⌘- / ⌘0 zoom the whole panel in four steps; the default is the smallest', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      Future<void> chord(LogicalKeyboardKey k) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(k);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await tester.tap(fieldFinder);
      await tester.pump();
      await chord(LogicalKeyboardKey.equal);
      expect(es.prefs.composerZoom, 1);
      expect(field(tester).style!.fontSize, closeTo(15 * 1.15, 1e-9));
      expect(rect(tester, 'composer-panel').width, closeTo(720 * 1.15, 1e-9));
      for (var i = 0; i < 6; i++) {
        await chord(LogicalKeyboardKey.equal);
      }
      expect(es.prefs.composerZoom, 4); // the top step
      expect(es.composerScale, 1.75);
      await chord(LogicalKeyboardKey.minus);
      expect(es.prefs.composerZoom, 3);
      await chord(LogicalKeyboardKey.digit0);
      expect(es.prefs.composerZoom, 0);
      expect(field(tester).style!.fontSize, 15);
      expect(rect(tester, 'composer-panel').width, 720);
      await chord(LogicalKeyboardKey.minus); // never under the default
      expect(es.prefs.composerZoom, 0);
    });

    testWidgets('open: one line, 720 wide, centred, standing on the desktop anchor', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      final host = rect(tester, 'host');
      final p = rect(tester, 'composer-panel');
      expect(p.size, const Size(720, 56 + 2)); // one line as tall as ＋/发送 and their 8s, inside a 1 px border
      expect(p.center.dx - host.left, 500);
      // Safari's 快捷区 is folded by default, so the panel is the whole block: its bottom on the anchor, a control's
      // height and 20 over the stage's bottom.
      expect(quickHidden(es, rs), isTrue);
      expect(p.bottom - host.top, 700 - desktopComposerAt(controlHeightFor(defaultTargetPlatform)).dy);
      // W2: 15 on 22, no MATRIX glow in the editor.
      final style = field(tester).style!;
      expect(style.fontSize, 15);
      expect(style.height, 22 / 15);
      expect(style.shadows, isEmpty);
    });

    testWidgets('the box is 30% see-through in every theme: the float fill at 0.7 of its alpha', (tester) async {
      big(tester);
      for (final theme in RappTheme.values) {
        await tester.pumpWidget(layer(theme: theme));
        await tester.pump(const Duration(seconds: 1));
        final d = tester.widget<Container>(find.byKey(const Key('composer-box'))).decoration! as BoxDecoration;
        final fill = d.color != null ? [d.color!] : (d.gradient! as LinearGradient).colors;
        final want = [for (final c in tokensFor(theme).float) c.withValues(alpha: c.a * composerFillOpacity)];
        expect(fill, want, reason: theme.name);
        expect(fill.every((c) => c.a < 1), isTrue, reason: theme.name);
      }
    });

    testWidgets('＋ on the left, 发送 on the right, no 快捷区 toggle in the box: 40 square, even 8, one-line box 56',
        (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      expect(find.byKey(const Key('quick-toggle')), findsNothing);
      final box = rect(tester, 'composer-box').deflate(1); // inside the 1 px border
      final plus = rect(tester, 'composer-plus'), send = rect(tester, 'composer-send');
      for (final r in [plus, send]) {
        expect(r.size, const Size(40, 40));
        expect(r.top - box.top, 8);
        expect(box.bottom - r.bottom, 8);
      }
      expect(plus.left - box.left, 8);
      expect(box.right - send.right, 8);
      expect(box.height, 56);
      // The text starts 16 right of ＋, as it ends 16 left of 发送.
      final editor = rect(tester, 'composer-field');
      expect(editor.left, plus.right + 16);
      expect(send.left - editor.right, 16);
    });

    testWidgets('zoomed in a narrow view: the keys give way so the text keeps 120 wide', (tester) async {
      es.setComposerZoom(4);
      final k = es.composerScale;
      for (final w in [320.0, 375.0, 390.0]) {
        await tester.pumpWidget(wrap(SizedBox(
            width: w,
            height: 700,
            child: Stack(children: composerLayer(state: es, session: rs, port: port, editor: FlutterEditor.new)))));
        await tester.pump();
        expect(rect(tester, 'composer-field').width, greaterThanOrEqualTo(120 - 1e-6), reason: 'stage $w');
        // Keep the requested 40..40*k size and the platform's existing density (compact on desktop).
        for (final key in ['composer-plus', 'composer-send']) {
          final r = rect(tester, key);
          expect(r.width, closeTo(r.height, 1e-6), reason: '$key at $w');
          final button = find.byKey(Key(key));
          final density = Theme.of(tester.element(button)).visualDensity.baseSizeAdjustment.dx;
          expect(r.width, inInclusiveRange(40 + density - 1e-6, 40 * k + 1e-6), reason: '$key at $w');
        }
      }
    }, variant: TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.linux}));

    testWidgets('zoomed and narrow', (tester) async {
      big(tester);
      es.setComposerZoom(4);
      await tester.pumpWidget(layer());
      await tester.pump();
      final k = es.composerScale;
      for (final key in ['composer-plus', 'composer-send']) {
        expect(rect(tester, key).size, Size(40 * k, 40 * k), reason: key);
      }
      expect(rect(tester, 'composer-box').deflate(1).height, closeTo(56 * k, 1e-9));
      es.setComposerZoom(0);
      await tester.pumpWidget(wrap(SizedBox(
          width: 320,
          height: 700,
          child: Stack(children: composerLayer(state: es, session: rs, port: port, editor: FlutterEditor.new)))));
      await tester.pump();
      expect(rect(tester, 'composer-field').width, greaterThan(100));
    });

    testWidgets('Linux: one-line text stays unscrolled at every zoom after toggling the quick area', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      await tester.enterText(fieldFinder, 'hello');
      for (var zoom = 0; zoom <= composerZoomMax; zoom++) {
        es.setComposerZoom(zoom);
        await tester.pumpAndSettle();
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.byKey(const Key('quick-toggle-stack')), kind: PointerDeviceKind.mouse);
          await tester.pumpAndSettle();
          final editable = find.descendant(of: fieldFinder, matching: find.byType(EditableText));
          final scroll = tester.state<ScrollableState>(find.descendant(of: editable, matching: find.byType(Scrollable)));
          expect(scroll.position.maxScrollExtent, 0, reason: 'zoom $zoom, toggle $i');
          expect(fieldFocused(tester), isTrue);
          expect(text(tester), 'hello');
        }
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('long text grows upward to half the stage, bottom and width fixed', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      final before = rect(tester, 'composer-panel');
      rs.composer.setDraft(List.generate(40, (i) => 'line $i').join('\n'));
      await tester.pump(); // W16: one frame, no animation
      final after = rect(tester, 'composer-panel');
      expect(after.height, greaterThan(before.height));
      expect(after.height, lessThanOrEqualTo(350));
      expect(after.bottom, before.bottom);
      expect(after.left, before.left);
      expect(after.width, before.width);
    });

    testWidgets('Enter sends and the box stays, one line, caret inside (W7); once all is in, 直接回车且隐藏 hides it', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      await tester.enterText(fieldFinder, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      final sent = callsOf('composer_send');
      expect(sent.single['sid'], 1);
      expect(sent.single['pieces'], [
        {'text': 'a'},
      ]);
      expect(text(tester), isEmpty);
      expect(rect(tester, 'composer-box').height, 58);
      expect(fieldFocused(tester), isTrue);
      expect(find.text('发送中'), findsOneWidget);
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
      await tester.pump();
      expect(find.text('发送中'), findsNothing);
      // The default 直接回车且隐藏: the Return goes and the panel hides.
      expect(rs.composer.open, isFalse);
      await tester.pumpAndSettle(); // the text area folds away
      expect(find.byKey(const Key('composer-panel')), findsNothing);
    });

    testWidgets('without 直接回车且隐藏 the panel stays once all is in', (tester) async {
      big(tester);
      rs.setProfile(const ResolvedProfile(afterSend: AfterSend.none));
      await tester.pumpWidget(layer());
      await tester.pump();
      await tester.enterText(fieldFinder, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
      await tester.pump();
      expect(rs.composer.open, isTrue);
      expect(find.byKey(const Key('composer-panel')), findsOneWidget);
      expect(fieldFocused(tester), isTrue);
    });

    for (final hard in [false, true]) {
      testWidgets('iOS ${hard ? 'with a hardware keyboard: the caret stays' : 'soft keyboard: it goes down'} once all is in',
          (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => lastHardwareKey = null);
        try {
          if (hard) lastHardwareKey = DateTime.now();
          big(tester);
          rs.setProfile(const ResolvedProfile(afterSend: AfterSend.none));
          await tester.pumpWidget(layer());
          await tester.pump();
          await tester.enterText(fieldFinder, 'a');
          await tester.tap(find.byKey(const Key('composer-send')));
          await tester.pump();
          expect(fieldFocused(tester), isTrue, reason: 'still sending');
          rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
          await tester.pump();
          expect(rs.composer.open, isTrue);
          expect(fieldFocused(tester), hard);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('iOS soft keyboard: a send that did not all go in keeps the caret', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        big(tester);
        rs.setProfile(const ResolvedProfile(afterSend: AfterSend.none));
        await tester.pumpWidget(layer());
        await tester.pump();
        await tester.enterText(fieldFinder, 'a');
        await tester.tap(find.byKey(const Key('composer-send')));
        await tester.pump();
        rs.apply(const ComposerStateEvent(1, done: ComposerDone(0, '没有发出去')));
        await tester.pump();
        expect(fieldFocused(tester), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('iOS: ⌃ once + typed r sends Ctrl-R, draft empty; the next typed r goes into the draft', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        keyLatchOf(es, rs).tap(latchCtrl);
        await tester.enterText(fieldFinder, 'r');
        await tester.pump();
        expect(text(tester), '');
        expect(callsOf('key').length, 1);
        expect(callsOf('key').single['modifiers'], latchCtrl);
        await tester.enterText(fieldFinder, 'r');
        await tester.pump();
        expect(text(tester), 'r');
        expect(callsOf('key').length, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the send button sends, and waits while a send runs', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      expect(find.bySemanticsLabel('发送'), findsOneWidget);
      await tester.enterText(fieldFinder, 'x');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').single['pieces'], [
        {'text': 'x'},
      ]);
      await tester.enterText(fieldFinder, 'y');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').length, 1);
      expect(text(tester), 'y');
    });

    testWidgets('a send switches A to English first; an empty Enter presses Return', (tester) async {
      rs.apply(const InputSourceEvent(1, 'im', '拼音', false));
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(callsOf('key'), [
        {'sid': 1, 'keyCode': 36, 'modifiers': 0},
      ]);
      expect(callsOf('composer_send'), isEmpty);
      expect(find.text('已给远端发回车'), findsNothing); // W11

      port.calls.clear();
      await tester.enterText(fieldFinder, 'hi');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect([for (final c in port.calls) c.$1].where((m) => m == 'select_input' || m == 'composer_send'),
          ['select_input', 'composer_send']);
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
      await tester.pump();
      expect(text(tester), isEmpty);
      expect(find.textContaining('已发送'), findsNothing); // W11
    });

    testWidgets('an empty Enter right after a send does nothing (W15)', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.enterText(fieldFinder, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
      await tester.pump();
      port.calls.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(callsOf('key'), isEmpty);
      expect(callsOf('composer_send'), isEmpty);
    });

    testWidgets('a failed send offers retry and put back', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.enterText(fieldFinder, 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(0, 'A 上贴不进去')));
      await tester.pump();
      expect(find.text('A 上贴不进去'), findsOneWidget);
      expect(text(tester), isEmpty);
      await tester.tap(find.text('放回输入框'));
      await tester.pump();
      expect(text(tester), 'hello');
      expect(find.text('A 上贴不进去'), findsNothing);

      // A block pasted at the caret, after the text; the text went, the block did not: 重试 sends what
      // is left.
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]')]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').last['pieces'], [
        {'text': 'hello'},
        {'block': 1},
      ]);
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, 'boom')));
      await tester.pump();
      expect(find.text('boom'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      final sent = callsOf('composer_send');
      expect(sent.length, 3);
      expect(sent.last['pieces'], [
        {'block': 1},
      ]);
      expect(find.text('boom'), findsNothing);
      expect(find.text('发送中'), findsOneWidget);
    });

    testWidgets('重试 is off while a send waits for the input method to commit (I1)', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.enterText(fieldFinder, 'x');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(0, 'boom')));
      await tester.pump();
      RappButton retry() => tester.widget<RappButton>(find.widgetWithText(RappButton, '重试'));
      expect(retry().onPressed, isNotNull);
      field(tester).controller!.value = const TextEditingValue(
          text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2));
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(rs.composer.taking, isTrue);
      expect(retry().onPressed, isNull);
      field(tester).controller!.value =
          const TextEditingValue(text: '你', selection: TextSelection.collapsed(offset: 1));
      await tester.pump();
      final sent = callsOf('composer_send');
      expect(sent.length, 2);
      expect(sent.last['pieces'], [
        {'text': '你'},
      ]);
      expect(rs.composer.failed.single.text, 'x');
      expect(retry().onPressed, isNull); // sending
    });

    testWidgets('blocks sit in the text as chips; one deleted goes at send, the rest in their places',
        (tester) async {
      rs.composer.setDraft('看');
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]'), BlockChip(2, '[文件 a 1 B]')]));
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      final f = tester.getRect(fieldFinder);
      final chip = tester.getRect(find.text('[图片 #1 10×20]'));
      expect(f.contains(chip.topLeft) && f.contains(chip.bottomRight), isTrue, reason: 'in the text, not above it');
      expect(find.text('[文件 a 1 B]'), findsOneWidget);
      final t = text(tester);
      expect(t, hasLength(3));
      // Backspace over the image, then more typing.
      await tester.enterText(fieldFinder, '看${t[2]}吧');
      await tester.pump();
      expect(find.text('[图片 #1 10×20]'), findsNothing);
      expect(callsOf('composer_drop_block'), isEmpty, reason: 'an undo can bring it back until the send');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').last['pieces'], [
        {'text': '看'},
        {'block': 2},
        {'text': '吧'},
      ]);
      expect(callsOf('composer_drop_block'), [
        equals({'sid': 1, 'block': 1}),
      ]);
    });

    testWidgets('the hint is 写给 <app>', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      expect(find.text('写给 Safari'), findsOneWidget);
    });

    testWidgets('tall: 发送 stays bottom right, ＋ bottom left (W13)', (tester) async {
      big(tester);
      rs.composer.setDraft(List.generate(10, (i) => 'line $i').join('\n'));
      await tester.pumpWidget(layer());
      await tester.pump();
      final box = rect(tester, 'composer-box');
      final send = rect(tester, 'composer-send');
      final plus = rect(tester, 'composer-plus');
      expect(box.height, greaterThan(100));
      expect(send.size, const Size(40, 40));
      expect(plus.size, const Size(40, 40));
      expect(send.bottom, box.bottom - 1 - 8); // 8 inside the 1 px border
      expect(plus.bottom, box.bottom - 1 - 8);
      expect(send.right, box.right - 1 - 8);
      expect(plus.left, box.left + 1 + 8);
    });

    testWidgets('⌘V pastes what the runner answers at the cursor', (tester) async {
      port.pasteReply = {'text': 'hello'};
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), [
        equals({'sid': 1}),
      ]);
      expect(text(tester), 'hello');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a paste asked for before the panel is shown runs once it is, once (K4)', (tester) async {
      port.pasteReply = {'text': 'a\nb'};
      rs.composer.requestPaste();
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), [
        equals({'sid': 1}),
      ]);
      expect(text(tester), 'a\nb');
      expect(fieldFocused(tester), isTrue);
      await tester.pump();
      expect(callsOf('composer_paste'), hasLength(1));
    });

    testWidgets('Linux paste waits for IME commit without replacing preedit', (tester) async {
      port.pasteReply = {'text': ' hello'};
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2),
      ));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), [equals({'sid': 1})]);
      expect(text(tester), 'ni');
      expect(field(tester).controller!.value.composing, const TextRange(start: 0, end: 2));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '你', selection: TextSelection.collapsed(offset: 1),
      ));
      await tester.pump();
      expect(text(tester), '你 hello');
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Linux Ctrl+V inserts an attachment block through the composer', (tester) async {
      port.pasteReply = {'blocks': [{'n': 1, 'label': 'image.png'}]};
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), [equals({'sid': 1})]);
      expect(rs.composer.blocks.single.label, 'image.png');
      expect(find.text('image.png'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('a paste asked for while the panel is shown runs at once', (tester) async {
      port.pasteReply = {'text': 'x'};
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      expect(callsOf('composer_paste'), isEmpty);
      rs.composer.requestPaste();
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), hasLength(1));
      expect(text(tester), 'x');
    });

    testWidgets('focusing the field takes focus from the picture', (tester) async {
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
          await flush();
        }
      });
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      es.focusPicture(1);
      await tester.tap(fieldFinder);
      await tester.pump();
      expect(es.pictureFocused, isNull);
      expect(port.calls.last.$1, 'picture_focus');
      expect(port.calls.last.$2, equals({'sid': null}));
    });

    testWidgets('no 「输入」 button and no panel while composerAllowed is false; both come back', (tester) async {
      RemoteWindow rw(int id, WindowKind k) => RemoteWindow(
          id: id,
          parent: 0,
          kind: k,
          title: 'w$id',
          rect: const Rect.fromLTWH(0, 0, 100, 100),
          titleBar: 28,
          resizable: true,
          focused: false,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1));
      rs.setProfile(const ResolvedProfile(
          name: 'X', windows: [WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer)]));
      rs.apply(WindowsEvent(1, [rw(1, WindowKind.normal)]));
      rs.apply(WindowsEvent(1, [rw(1, WindowKind.normal), rw(2, WindowKind.dialog)]));
      rs.composer.setDraft('草稿');
      await tester.pumpWidget(wrap(SizedBox(
          width: 900, height: 400, child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
      expect(find.byKey(const Key('composer-panel')), findsNothing);
      expect(find.byKey(const Key('composer-open')), findsNothing);
      rs.selectWindow(1);
      await tester.pump();
      expect(find.byKey(const Key('composer-panel')), findsOneWidget);
      expect(text(tester), '草稿');
    });

    testWidgets('the upload strip and cancel stay while composerAllowed is false; only 输入 goes', (tester) async {
      rs.setProfile(const ResolvedProfile(name: 'X', composer: false));
      rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
      await tester.pumpWidget(wrap(SizedBox(
          width: 900, height: 400, child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
      expect(find.byKey(const Key('composer-open')), findsNothing);
      expect(find.text('上传 1/2 · a.txt'), findsOneWidget);
      await tester.tap(find.text('取消'));
      expect(callsOf('cancel_transfer').single, equals({'sid': 1}));
    });

    // What a secondary button over the picture fills with (AVATAR's raise is see-through).
    double fillAlpha(WidgetTester tester, Finder button) => tester
        .widget<OutlinedButton>(find.descendant(of: button, matching: find.byType(OutlinedButton)))
        .style!
        .backgroundColor!
        .resolve(<WidgetState>{})!
        .a;

    testWidgets('输入 and 取消 over the picture are opaque in AVATAR', (tester) async {
      rs.composer.open = false;
      rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
      await tester.pumpWidget(wrap(
          SizedBox(width: 900, height: 400, child: Stack(children: composerLayer(state: es, session: rs, port: port))),
          theme: RappTheme.avatar));
      expect(fillAlpha(tester, find.byKey(const Key('composer-open'))), 1.0);
      expect(fillAlpha(tester, find.widgetWithText(RappButton, '取消')), 1.0);
    });

    testWidgets('the hint line\'s 取消 is opaque in AVATAR', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
      await tester.pumpWidget(wrap(
          SizedBox(width: 900, height: 600, child: Stack(children: composerLayer(state: es, session: rs, port: port))),
          theme: RappTheme.avatar));
      await tester.pump();
      final hint = find.byKey(const Key('composer-hint'));
      expect(fillAlpha(tester, find.descendant(of: hint, matching: find.widgetWithText(RappButton, '取消'))), 1.0);
    });

    group('plus menu and hint line', () {
      final menu = find.byKey(const Key('composer-plus-menu'));
      final hint = find.byKey(const Key('composer-hint'));

      Future<void> openMenu(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('composer-plus')));
        await tester.pump();
      }

      testWidgets('on a 320 phone the menu stays inside the stage, 8 from either edge', (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(wrap(SizedBox(
            width: 320,
            height: 700,
            child: Stack(children: composerLayer(state: es, session: rs, port: port, editor: FlutterEditor.new)))));
        await tester.pump();
        await openMenu(tester);
        final r = tester.getRect(menu);
        expect(r.left, greaterThanOrEqualTo(8 - 1e-6));
        expect(r.right, lessThanOrEqualTo(312 + 1e-6));
      }, variant: TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.linux}));

      testWidgets('「大小」 slides the zoom; the menu keeps its own size at the top step', (tester) async {
        big(tester);
        es.setComposerZoom(composerZoomMax);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        expect(tester.takeException(), isNull); // no row overflows at 175%
        expect(tester.getRect(menu).width, 300);
        expect(find.text('175%'), findsOneWidget);
        tester.widget<Slider>(find.byType(Slider)).onChanged!(1);
        await tester.pump();
        expect(es.composerZoom.value, 1);
        expect(es.prefs.composerZoom, 1);
        expect(find.text('115%'), findsOneWidget);
        expect(rect(tester, 'composer-panel').width, closeTo(720 * 1.15, 1e-9));
        es.setComposerZoom(0);
      });

      for (final platform in [TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.iOS]) {
        testWidgets('${platform.name} ＋ menu: 附件, 在远端复制, 输入历史, 直接回车且隐藏, 大小, 快捷区 group, 收起; no key grid',
            (tester) async {
          big(tester);
          final x = RemoteSession(3, 'Notes', appId: 'com.x')..composer.open = true;
          addTearDown(x.dispose);
          await tester.pumpWidget(layer(s: x));
          await tester.pump();
          expect(menu, findsNothing);
          expect(find.bySemanticsLabel('更多'), findsOneWidget);
          await openMenu(tester);
          final m = tester.getRect(menu);
          final plus = rect(tester, 'composer-plus');
          expect(m.width, 300);
          expect(m.bottom, plus.top - 8);
          expect(m.left, plus.left);
          expect(m.left, greaterThanOrEqualTo(rect(tester, 'host').left));
          expect(find.text('按键 · 直接发给远端'), findsNothing);
          for (final l in ['Tab', '⌘', '⌥', '删除', '←', '↓', '↑', '→', '回车']) {
            expect(find.descendant(of: menu, matching: find.text(l)), findsNothing, reason: l);
          }
          expect(find.text('附件…'), findsOneWidget);
          expect(find.text('也可以直接粘贴'), findsOneWidget);
          expect(find.text('在远端复制'), findsOneWidget);
          expect(find.text(platform == TargetPlatform.macOS ? '⌘C' : 'Ctrl+C'), findsOneWidget);
          expect(find.text('输入历史'), findsOneWidget);
          expect(find.byKey(const Key('composer-plus-quick')), findsOneWidget);
          expect(find.text('收起'), findsOneWidget);
          // Vertical order.
          double y(Finder f) => tester.getCenter(f).dy;
          final order = [
            find.text('附件…'),
            find.text('在远端复制'),
            find.text('输入历史'),
            find.text('直接回车且隐藏'),
            find.text('大小'),
            find.byKey(const Key('composer-plus-quick')),
            find.text('打字后自动收起'),
            find.text('显示常用语条'),
            find.text('更多按键'),
            find.text('编辑常用语…'),
            find.byKey(const Key('composer-plus-collapse')),
          ];
          for (var i = 1; i < order.length; i++) {
            expect(y(order[i]), greaterThan(y(order[i - 1])), reason: 'row $i');
          }
        }, variant: TargetPlatformVariant.only(platform));
      }

      testWidgets('a short stage (390 tall): the menu fits inside the view and 收起 scrolls into reach', (tester) async {
        tester.view.physicalSize = const Size(900, 390);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        final m = tester.getRect(menu);
        expect(m.top, greaterThanOrEqualTo(0));
        expect(m.bottom, lessThanOrEqualTo(390));
        final collapse = find.byKey(const Key('composer-plus-collapse'));
        await tester.scrollUntilVisible(collapse, 80, scrollable: find.descendant(of: menu, matching: find.byType(Scrollable)));
        await tester.tap(collapse);
        await tester.pump();
        expect(menu, findsNothing);
        expect(rs.composer.open, isFalse);
      });

      testWidgets('快捷区 switches flip quickAutoHide, phraseStrip, keyBarMore and the menu stays open', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        bool on(String k) => tester.widget<Switch>(find.descendant(of: find.byKey(Key(k)), matching: find.byType(Switch))).value;
        final auto0 = es.quickAutoHide;
        final strip0 = es.prefs.phraseStrip;
        final more0 = es.prefs.keyBarMore;
        expect(on('quick-auto-hide'), auto0);
        expect(on('quick-phrase-strip'), strip0);
        expect(on('quick-more'), more0);
        await tester.tap(find.byKey(const Key('quick-auto-hide')));
        await tester.pump();
        expect(es.quickAutoHide, !auto0);
        expect(on('quick-auto-hide'), !auto0);
        await tester.tap(find.byKey(const Key('quick-phrase-strip')));
        await tester.pump();
        expect(es.prefs.phraseStrip, !strip0);
        expect(on('quick-phrase-strip'), !strip0);
        await tester.tap(find.byKey(const Key('quick-more')));
        await tester.pump();
        expect(es.prefs.keyBarMore, !more0);
        expect(on('quick-more'), !more0);
        expect(menu, findsOneWidget);
      });

      testWidgets('打字后自动收起 shows on for macOS by default', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        final sw = find.descendant(of: find.byKey(const Key('quick-auto-hide')), matching: find.byType(Switch));
        expect(tester.widget<Switch>(sw).value, isTrue);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('打字后自动收起 shows off for iOS by default', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        final sw = find.descendant(of: find.byKey(const Key('quick-auto-hide')), matching: find.byType(Switch));
        expect(tester.widget<Switch>(sw).value, isFalse);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

      testWidgets('编辑常用语… closes the menu and pushes PhrasesPage', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.byKey(const Key('quick-edit-phrases')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(menu, findsNothing);
        expect(find.byType(PhrasesPage), findsOneWidget);
      });

      testWidgets('plus menu opens up from a panel at the bottom', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        expect(tester.getRect(menu).bottom, lessThanOrEqualTo(rect(tester, 'composer-plus').top));
      });

      testWidgets('plus menu opens down from a panel near the top', (tester) async {
        big(tester);
        es.profiles.setComposerAt('Notes', 'Notes', const InputPoint(0.5, 200));
        rs.setProfile(es.profiles.resolve('Notes'));
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        final m = tester.getRect(menu);
        final plus = rect(tester, 'composer-plus');
        final host = rect(tester, 'host');
        expect(m.top, plus.bottom + 8);
        expect(m.left, plus.left);
        expect(m.left, greaterThanOrEqualTo(host.left));
        expect(m.top, greaterThanOrEqualTo(host.top));
        expect(m.bottom, lessThanOrEqualTo(host.bottom));
      });

      testWidgets('the copy shortcut reads ⌘C on macOS', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        expect(find.text('⌘C'), findsOneWidget);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('在远端复制 sends ⌘C and the hint line says 已复制', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.text('在远端复制'));
        await tester.pump();
        expect(callsOf('key').single, equals({'sid': 1, 'keyCode': 8, 'modifiers': 1048576}));
        expect(menu, findsNothing);
        expect(find.descendant(of: hint, matching: find.text('已复制')), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
      });

      testWidgets('附件… asks the runner and the menu closes', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.text('附件…'));
        await tester.pump();
        expect(callsOf('composer_attach').single, equals({'sid': 1}));
        expect(menu, findsNothing);
      });

      testWidgets('收起 closes the panel and keeps the text', (tester) async {
        big(tester);
        rs.composer.setDraft('草稿');
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.text('收起'));
        await tester.pump();
        await tester.pump();
        expect(menu, findsNothing);
        await tester.pumpAndSettle(); // the text area folds away
        expect(find.byKey(const Key('composer-panel')), findsNothing);
        expect(rs.composer.open, isFalse);
        expect(rs.composer.draft, '草稿');
      });

      testWidgets('收起 sits on the right of its row, near ＋, with Esc as its shortcut', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        final row = find.byKey(const Key('composer-plus-collapse'));
        final m = tester.getRect(menu);
        final label = tester.getRect(find.descendant(of: row, matching: find.text('收起')));
        final esc = tester.getRect(find.descendant(of: row, matching: find.text('Esc')));
        expect(m.right - label.right, lessThan(30));
        expect(esc.right, lessThan(label.left));
      });

      testWidgets('直接回车且隐藏: checked by default, a tap turns it off for this app and keeps the menu open', (tester) async {
        big(tester);
        final x = RemoteSession(3, 'Notes', appId: 'com.x')..composer.open = true;
        addTearDown(x.dispose);
        x.setProfile(es.profiles.resolve('com.x'));
        void sync() => x.setProfile(es.profiles.resolve('com.x'));
        es.profiles.addListener(sync);
        addTearDown(() => es.profiles.removeListener(sync));
        await tester.pumpWidget(layer(s: x));
        await tester.pump();
        await openMenu(tester);
        final row = find.byKey(const Key('composer-plus-return'));
        bool on() => tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value;
        expect(find.descendant(of: row, matching: find.text('直接回车且隐藏')), findsOneWidget);
        expect(on(), isTrue);
        await tester.tap(row);
        await tester.pump();
        expect(menu, findsOneWidget);
        expect(es.profiles.resolve('com.x').afterSend, AfterSend.none);
        expect(on(), isFalse);
        await tester.tap(row);
        await tester.pump();
        expect(es.profiles.resolve('com.x').afterSend, AfterSend.pressReturn);
        expect(on(), isTrue);
      });

      testWidgets('直接回车且隐藏 is not offered for a session without an app id', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        expect(find.byKey(const Key('composer-plus-return')), findsNothing);
      });

      testWidgets('the menu never carries over to another session', (tester) async {
        big(tester);
        final rs2 = RemoteSession(2, 'Notes');
        addTearDown(rs2.dispose);
        rs2.composer.open = true;
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.pumpWidget(layer(s: rs2));
        await tester.pump();
        expect(menu, findsNothing);
      });

      testWidgets('hint line: A on an input method, accent, a tap switches to English', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        expect(hint, findsNothing);
        rs.apply(const InputSourceEvent(1, 'im', '拼音', false));
        await tester.pump();
        const line = '远端在用输入法 拼音，发送前会切到英文 · 点按现在就切';
        expect(find.descendant(of: hint, matching: find.text(line)), findsOneWidget);
        final style = tester.widget<Text>(find.text(line)).style!;
        expect(style.color, RappTokens.of(tester.element(hint)).accent);
        expect(style.fontWeight, FontWeight.w600);
        await tester.tap(find.text(line));
        await tester.pump();
        expect(callsOf('select_input').single, equals({'sid': 1, 'id': ''}));
        rs.apply(const InputSourceEvent(1, 'ascii', 'ABC', true));
        await tester.pump();
        expect(find.text(line), findsNothing);
        expect(hint, findsNothing);
      });

      testWidgets('hint line: an upload shows its progress with 取消', (tester) async {
        big(tester);
        rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
        await tester.pumpWidget(layer());
        await tester.pump();
        expect(find.descendant(of: hint, matching: find.text('上传 1/2 · a.txt')), findsOneWidget);
        await tester.tap(find.descendant(of: hint, matching: find.text('取消')));
        expect(callsOf('cancel_transfer').single, equals({'sid': 1}));
      });

      testWidgets('hint line on a narrow stage: long texts ellipsize, nothing overflows (m4)', (tester) async {
        big(tester);
        rs.apply(TransferStatusEvent(1, '上传 1/2 · ${'很长的文件名' * 10}.txt'));
        rs.apply(const InputSourceEvent(1, 'im', '拼音', false));
        await tester.pumpWidget(wrap(SizedBox(
            width: 360, height: 700, child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
        await tester.pump();
        rs.composer.note('已贴入 ${'一张很大的图' * 10}');
        await tester.pump();
        expect(tester.takeException(), isNull);
        for (final t in tester.widgetList<Text>(find.descendant(of: hint, matching: find.byType(Text)))) {
          if (t.data == '取消') continue;
          expect(t.maxLines, 1, reason: t.data);
          expect(t.overflow, TextOverflow.ellipsis, reason: t.data);
        }
        expect(find.descendant(of: hint, matching: find.text('取消')), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets('hint line: a paste or attach note shows and goes', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        rs.composer.apply(const PasteResult(status: '已贴入 1 张图'));
        await tester.pump();
        expect(find.descendant(of: hint, matching: find.text('已贴入 1 张图')), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        expect(hint, findsNothing);
      });

      testWidgets('hint line is gone when nothing is going on', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        expect(hint, findsNothing);
      });
    });

    testWidgets('M3.1: long text with chips in it stays inside the box', (tester) async {
      big(tester);
      rs.composer.setDraft(List.generate(40, (i) => 'line $i').join('\n'));
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]'), BlockChip(2, '[文件 a 1 B]')]));
      await tester.pumpWidget(layer());
      await tester.pump();
      final box = rect(tester, 'composer-box');
      expect(box.height, lessThanOrEqualTo(350));
      final f = tester.getRect(fieldFinder);
      expect(f.bottom, lessThanOrEqualTo(box.bottom));
      expect(f.height, greaterThanOrEqualTo(48));
      expect(find.text('[文件 a 1 B]'), findsOneWidget);
    });

    testWidgets('M3.1: a self-sizing editor is handed the whole box, blocks or not', (tester) async {
      final ed = FakeEditor()..selfSizing = true;
      Widget withEditor() => wrap(SizedBox(
          width: 720, child: ComposerPanel(state: es, session: rs, port: port, maxHeight: 350, editor: () => ed)));
      await tester.pumpWidget(withEditor());
      await tester.pump();
      expect(ed.lastMaxHeight, 340); // 350 less the border and 4 above and below
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]'), BlockChip(2, '[文件 a 1 B]')]));
      await tester.pump();
      expect(ed.lastMaxHeight, 340, reason: 'no blocks row above the text any more');
      expect(ed.labels.values, ['[图片 #1 10×20]', '[文件 a 1 B]']);
      expect(ed.shown, '[[图片 #1 10×20]][[文件 a 1 B]]');
    });

    testWidgets('M3.1: the editor is never handed under one line', (tester) async {
      final ed = FakeEditor()..selfSizing = true;
      await tester.pumpWidget(wrap(SizedBox(
          width: 600, child: ComposerPanel(state: es, session: rs, port: port, maxHeight: 30, editor: () => ed))));
      await tester.pump();
      expect(ed.lastMaxHeight, 48);
    });

    testWidgets('many failed rows scroll; the hint line, the editor and 发送 stay on stage (I2)', (tester) async {
      big(tester);
      rs.setProfile(const ResolvedProfile(afterSend: AfterSend.none));
      for (var i = 0; i < 8; i++) {
        rs.composer.setDraft('row $i');
        await rs.composer.submit();
        rs.composer.done(0, 'boom');
      }
      rs.composer.note('已粘贴');
      await tester.pumpWidget(wrap(SizedBox(
          key: const Key('host'),
          width: 800,
          height: 400,
          child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final host = rect(tester, 'host');
      bool inside(Rect r) => host.contains(r.topLeft) && host.contains(r.bottomRight - const Offset(0.01, 0.01));
      expect(inside(rect(tester, 'composer-send')), isTrue);
      expect(inside(rect(tester, 'composer-hint')), isTrue);
      expect(inside(tester.getRect(fieldFinder)), isTrue);
      await tester.enterText(fieldFinder, 'z');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').last['pieces'], [
        {'text': 'z'},
      ]);
      rs.composer.done(1, null);
      await tester.pump();
      // The rows open at the bottom: the last one sits right above the hint line.
      expect(tester.getRect(find.text('row 7')).bottom, lessThanOrEqualTo(rect(tester, 'composer-hint').top));
      expect(inside(tester.getRect(find.text('row 7'))), isTrue);
      await tester.pump(const Duration(seconds: 5)); // the note and the idle copy
    });

    testWidgets('M3.2: a long failure ellipsizes and 重试 / 放回输入框 stay', (tester) async {
      await tester.pumpWidget(
          wrap(SizedBox(width: 600, child: ComposerPanel(state: es, session: rs, port: port, maxHeight: 300, editor: FlutterEditor.new))));
      await tester.pump();
      await tester.enterText(fieldFinder, 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(ComposerStateEvent(1, done: ComposerDone(0, '失败' * 100)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('放回输入框'), findsOneWidget);
    });
  });

  group('还原', () {
    late RemoteSession rs;
    late FakeSessionPort zport;
    const stage = Size(1000, 700);

    RemoteWindow zw(int id) => RemoteWindow(
        id: id,
        parent: 0,
        kind: WindowKind.normal,
        title: 'w$id',
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        titleBar: 28,
        resizable: true,
        focused: true,
        texture: id,
        visible: const Rect.fromLTWH(0, 0, 1, 1));

    RemoteSession make(SessionPort p) {
      final r = RemoteSession(1, 'Safari', onView: (w, rect, z) => p.setView(1, w, rect, z));
      r.apply(WindowsEvent(1, [zw(7)]));
      return r;
    }

    Widget layerFor(SessionPort p) => wrap(SizedBox(
        width: 1000,
        height: 700,
        child: Stack(children: composerLayer(state: es, session: rs, port: p, editor: FlutterEditor.new))));

    // The restore runs on frame callbacks: the first only starts the clock, the tail timer keeps 1 s.
    Future<void> restored(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 2));
    }

    void zoom() => rs.zoomOf(7).zoomTo(2, const Offset(500, 350), fitRect(const Size(100, 100), stage), stage);

    setUp(() {
      zport = FakeSessionPort();
      rs = make(zport);
    });
    tearDown(() => rs.dispose());

    testWidgets('zoom-reset shows only while the current window is zoomed', (tester) async {
      await tester.pumpWidget(layerFor(zport));
      expect(find.byKey(const Key('zoom-reset')), findsNothing);
      zoom();
      await tester.pump();
      expect(find.byKey(const Key('zoom-reset')), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('zoom-reset'))).right,
          lessThan(tester.getRect(find.byKey(const Key('composer-open'))).left));
      rs.zoomOf(7).restore();
      await restored(tester);
      expect(find.byKey(const Key('zoom-reset')), findsNothing);
    });

    testWidgets('zoom-reset restores and sends unlimited once', (tester) async {
      await tester.pumpWidget(layerFor(zport));
      rs.view.settled(7, const Rect.fromLTWH(10, 10, 20, 20), const Size(100, 100), 2);
      zoom();
      await tester.pump();
      final before = zport.calls.where((c) => c.$1 == 'set_view').length;
      await tester.tap(find.byKey(const Key('zoom-reset')));
      await restored(tester);
      expect(rs.zoomOf(7).z, 1);
      final sent = zport.calls.where((c) => c.$1 == 'set_view').toList();
      expect(sent.length, before + 1);
      expect(sent.last.$2['window'], 0);
    });

    testWidgets('还原 hides while the text area is open', (tester) async {
      zoom();
      await tester.pumpWidget(layerFor(zport));
      expect(find.byKey(const Key('zoom-reset')), findsOneWidget);
      rs.composer.open = true;
      await tester.pump();
      expect(find.byKey(const Key('zoom-reset')), findsNothing);
    });

    testWidgets('terminal: zoom-reset restores the terminal zoom and sends nothing', (tester) async {
      final tport = FakeTermSessionPort();
      addTearDown(tport.dispose);
      rs.dispose();
      rs = make(tport);
      await tester.pumpWidget(layerFor(tport));
      zoom();
      await tester.pump();
      await tester.tap(find.byKey(const Key('zoom-reset')));
      await restored(tester);
      expect(rs.zoomOf(7).z, 1);
      expect(tport.calls.where((c) => c.$1 == 'set_view'), isEmpty);
    });
  });

  group('stage', () {
    RemoteWindow rw(int id, double w, double h) => RemoteWindow(
          id: id,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w$id',
          rect: Rect.fromLTWH(0, 0, w, h),
          titleBar: 28,
          resizable: true,
          focused: true,
          texture: 42,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    // What stands under the panel in its block: the 快捷区 and its 8 while shown (Safari folds it by default).
    double bar() => quickHidden(es, es.currentRemote!) ? 0 : keyBarHeightOf(es, es.currentRemote!) + 8;
    // The block's default bottom on the 800×600 stage: the desktop anchor.
    double home() => 600 - desktopComposerAt(controlHeightFor(defaultTargetPlatform)).dy;

    Future<void> openEmbedded(WidgetTester tester, {int sid = 1, String app = 'Safari'}) async {
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': sid, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5000 + sid, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.openOrSwitch('111', app, app);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
    }

    testWidgets('opening the composer does not resize A', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      await tester.pump();
      final before = tester.getSize(find.byKey(const Key('stage')));
      port.calls.removeWhere((c) => c.$1 == 'resize');
      expect(find.byType(ComposerPanel), findsNothing);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ComposerPanel), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('stage'))), before);
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
      // R18: the draft and open state are the session's.
      expect(es.currentRemote!.composer.open, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ComposerPanel), findsNothing);
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    });

    // Like MainWindow: a focused Focus above everything, and a CallbackShortcuts Esc (fullscreen).
    var escs = 0;
    var stageSize = const Size(800, 600);
    Widget mainLike() => CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => escs++},
          child: Focus(
              autofocus: true,
              child: SizedBox(width: stageSize.width, height: stageSize.height, child: Stage(state: es))),
        );

    // [reduced]: the platform asks for reduced motion.
    Future<void> showPicture(WidgetTester tester, {bool reduced = false}) async {
      escs = 0;
      stageSize = const Size(800, 600);
      await tester.pumpWidget(wrap(mainLike(), disableAnimations: reduced));
      await tester.pump();
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      es.focusPicture(1);
      await tester.pump();
    }

    double top(WidgetTester tester) => tester.getTopLeft(find.byType(Picture)).dy;

    Rect panelRect(WidgetTester tester) => tester.getRect(find.byKey(const Key('composer-panel')));
    final grip = find.byKey(const Key('composer-grip'));

    Future<void> openPanel(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pumpAndSettle();
    }

    // One touch drag on the grip, pumping after each move.
    Future<void> dragGrip(WidgetTester tester, List<Offset> moves) async {
      final g = await tester.startGesture(tester.getCenter(grip));
      for (final m in moves) {
        await g.moveBy(m);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout); // the grip also waits for a second tap
    }

    // A compose letter (type-to-compose): the editor takes the caret, the picture lets go of the
    // keys, and only then the runner is asked to replay the letter.
    Future<void> composeKey(WidgetTester tester) async {
      port.calls.clear();
      port.emit(const ComposeKeyEvent(1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final names = [for (final c in port.calls) c.$1];
      expect(es.currentRemote!.composer.editorFocused, isTrue);
      expect(es.pictureFocused, isNull);
      expect(names.where((m) => m == 'compose_replay').length, 1);
      final blur = port.calls.indexWhere((c) => c.$1 == 'picture_focus' && c.$2['sid'] == null);
      expect(blur, greaterThanOrEqualTo(0));
      expect(blur, lessThan(names.indexOf('compose_replay')));
      expect(port.calls.firstWhere((c) => c.$1 == 'compose_replay').$2, {'sid': 1});
    }

    testWidgets('compose_key: caret in the editor, picture blurred, then replay', (tester) async {
      await showPicture(tester);
      expect(find.byType(ComposerPanel), findsNothing);
      await composeKey(tester);
      expect(find.byType(ComposerPanel), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('compose_key: the replay waits for the switch to Chinese', (tester) async {
      es.dispose();
      final ime = _GatedIme();
      es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, localIme: ime);
      await showPicture(tester);
      port.calls.clear();
      port.emit(const ComposeKeyEvent(1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(es.currentRemote!.composer.editorFocused, isTrue);
      await tester.pump(Duration.zero); // the switch is settled on a zero timer
      expect(ime.calls, ['toChinese']);
      expect(callsOf('compose_replay'), isEmpty); // the input method is still switching
      ime.gate.complete('im.rime');
      await tester.pump();
      expect(callsOf('compose_replay'), [
        {'sid': 1}
      ]);
      await tester.pump(const Duration(seconds: 2));
      // The panel going away with the caret in it switches back.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      expect(ime.calls, ['toChinese']); // a leave waits its grace: another panel may take the caret
      await tester.pump(ImeIntent.defaultLeaveGrace);
      expect(ime.calls, ['toChinese', 'toEnglish']);
    });

    testWidgets('compose_key: the wait for the input method is bounded to 300 ms in all', (tester) async {
      es.dispose();
      final ime = _HungIme();
      es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, localIme: ime);
      await showPicture(tester);
      port.emit(const ComposeKeyEvent(1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(callsOf('compose_replay'), hasLength(1));
      // Back to the picture (Ctrl+Enter): the leave fires after its grace, and its two calls hang 300 ms each.
      es.composerKey();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(ime.calls, ['toChinese', 'current']);
      port.calls.clear();
      port.emit(const ComposeKeyEvent(1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      // The switch to Chinese is still queued behind the leave, but the letter does not wait for it.
      expect(ime.calls, ['toChinese', 'current', 'toEnglish']);
      expect(callsOf('compose_replay'), [
        {'sid': 1}
      ]);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('compose_key: no replay when the caret left the panel while the switch was settling', (tester) async {
      es.dispose();
      final ime = _GatedIme();
      es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, localIme: ime);
      await showPicture(tester);
      port.calls.clear();
      port.emit(const ComposeKeyEvent(1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(Duration.zero);
      expect(ime.calls, ['toChinese']);
      es.composerKey(); // Ctrl+Enter: the caret goes back to the picture before the switch ended
      await tester.pump();
      expect(es.currentRemote!.composer.editorFocused, isFalse);
      ime.gate.complete('im.rime');
      await tester.pump(Duration.zero); // the leave's settle runs, and the wait ends
      await tester.pump();
      expect(callsOf('compose_replay'), isEmpty);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('compose_key with the panel open but the picture focused', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      es.focusPicture(1);
      await tester.pump();
      expect(es.pictureFocused, 1);
      await composeKey(tester);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('no replay without compose_key', (tester) async {
      await showPicture(tester);
      port.calls.clear();
      await openPanel(tester);
      expect(port.calls.where((c) => c.$1 == 'compose_replay'), isEmpty);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('opening, growing and closing never move the picture; A is never resized', (tester) async {
      await showPicture(tester);
      final y0 = top(tester);
      final size0 = tester.getSize(find.byKey(const Key('stage')));
      port.calls.removeWhere((c) => c.$1 == 'resize');
      await openPanel(tester);
      expect(top(tester), y0);
      es.currentRemote!.composer.setDraft(List.generate(10, (i) => 'line $i').join('\n'));
      await tester.pumpAndSettle();
      expect(top(tester), y0);
      expect(tester.getSize(find.byKey(const Key('stage'))), size0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(top(tester), y0);
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    });

    testWidgets('a click on the picture with the panel open lands as with it closed', (tester) async {
      List<Map<String, Object?>> downs() =>
          port.calls.where((c) => c.$1 == 'mouse' && c.$2['kind'] == 'down').map((c) => c.$2).toList();
      await showPicture(tester);
      final g0 = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g0.down(tester.getCenter(find.byType(Picture)));
      await g0.up();
      await tester.pump();
      final plain = downs().single;
      port.calls.clear();
      await openPanel(tester);
      port.calls.clear();
      final seen = tester.getCenter(find.byType(Picture));
      expect(seen.dy, 300);
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(seen);
      await g.up();
      await tester.pump();
      final open = downs().single;
      expect(open['x'], plain['x']);
      expect(open['y'], plain['y']);
    });

    testWidgets('the panel starts bottom centre on the desktop anchor, the grip above it', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      final p = panelRect(tester);
      expect(p.bottom, home() - bar());
      expect(p.center.dx, 400);
      final g = tester.getRect(grip);
      expect(g.width, greaterThanOrEqualTo(48));
      expect(g.height, greaterThanOrEqualTo(20));
      expect(g.bottom, p.top);
      expect(g.center.dx, 400);
    });

    testWidgets('the grip bar shows with the mouse over the panel, while dragging, and after a touch', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      double bar() => tester.widget<AnimatedOpacity>(find.byKey(const Key('composer-grip-bar'))).opacity;
      expect(bar(), 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 20));
      await mouse.moveTo(panelRect(tester).center);
      await tester.pump();
      expect(bar(), 1);
      await mouse.moveTo(tester.getCenter(grip));
      await tester.pump();
      expect(bar(), 1);
      await mouse.moveTo(const Offset(400, 20));
      await tester.pump();
      expect(bar(), 0);
      // A touch drag shows it while it moves, and after: a touch screen has no hover.
      final g = await tester.startGesture(tester.getCenter(grip));
      await g.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(bar(), 1);
      await g.up();
      await tester.pump();
      expect(bar(), 1);
      // A tap elsewhere hides it again.
      await tester.tapAt(const Offset(400, 20));
      await tester.pump();
      expect(bar(), 0);
      await mouse.removePointer();
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('a touch on the panel shows the bar (no hover to show it)', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      double bar() => tester.widget<AnimatedOpacity>(find.byKey(const Key('composer-grip-bar'))).opacity;
      expect(bar(), 0);
      await tester.tapAt(tester.getCenter(fieldFinder));
      await tester.pump();
      expect(bar(), 1);
    });

    testWidgets('dragging the grip moves the panel and saves once on release', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      var saves = 0;
      es.profiles.addListener(() => saves++);
      final g = await tester.startGesture(tester.getCenter(grip));
      for (final m in const [Offset(-10, -100), Offset(-5, -50), Offset(-5, -50)]) {
        await g.moveBy(m);
        await tester.pump();
      }
      expect(saves, 0);
      expect(panelRect(tester).bottom, home() - 200 - bar());
      expect(panelRect(tester).center.dx, 380);
      await g.up();
      await tester.pump();
      expect(saves, 1);
      expect(es.profiles.resolve('Safari').composerAt, InputPoint.at(Offset(380, home() - 200 - bar()), const Size(800, 600)));
      expect(panelRect(tester).bottom, home() - 200 - bar());
      expect(panelRect(tester).center.dx, 380);
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('double-tap on the grip goes back to the default', (tester) async {
      es.profiles.setComposerAt('Safari', 'Safari', const InputPoint(0.5, 100));
      await showPicture(tester);
      await openPanel(tester);
      expect(panelRect(tester).bottom, 100);
      expect(panelRect(tester).center.dx, 400);
      await tester.tap(grip);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(grip);
      await tester.pumpAndSettle();
      expect(es.profiles.resolve('Safari').composerAt, isNull);
      expect(panelRect(tester).bottom, home() - bar());
      expect(panelRect(tester).center.dx, 400);
      expect(fieldFocused(tester), isTrue);
    });

    testWidgets('a drag keeps the text and the caret', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      await tester.enterText(fieldFinder, 'keep');
      await tester.pump();
      await dragGrip(tester, const [Offset(0, -150), Offset(0, -50)]);
      expect(panelRect(tester).bottom, home() - 200 - bar());
      expect(text(tester), 'keep');
      expect(fieldFocused(tester), isTrue);
    });

    testWidgets('no dead zone past the edge', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      // 720 wide on 800: the centre can go from 368 to 432.
      await dragGrip(tester, const [Offset(2000, 0), Offset(-50, 0)]);
      expect(panelRect(tester).center.dx, 382);
      expect(panelRect(tester).bottom, home() - bar());
    });

    testWidgets('a touch held still on the grip, then moved, still drags (no long-press tooltip)', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      final g = await tester.startGesture(tester.getCenter(grip));
      await tester.pump(const Duration(milliseconds: 800));
      await g.moveBy(const Offset(0, -100));
      await tester.pump();
      await g.moveBy(const Offset(0, -100));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout);
      expect(panelRect(tester).bottom, home() - 200 - bar());
      expect(find.text('拖动；双击回到底部居中'), findsNothing);
    });

    Offset blank(WidgetTester tester) {
      // Under 发送, in its 8 to the border: on the panel, off the text.
      final box = tester.getRect(find.byKey(const Key('composer-box')));
      final send = tester.getRect(find.byKey(const Key('composer-send')));
      return Offset(send.center.dx, box.bottom - 4);
    }

    for (final kind in const [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      testWidgets('a ${kind.name} drag anywhere on the panel off the text moves it', (tester) async {
        await showPicture(tester);
        await openPanel(tester);
        final g = await tester.startGesture(blank(tester), kind: kind);
        for (final m in const [Offset(-10, -100), Offset(-10, -100)]) {
          await g.moveBy(m);
          await tester.pump();
        }
        await g.up();
        await tester.pump();
        await tester.pump(kDoubleTapTimeout);
        expect(panelRect(tester).bottom, home() - 200 - bar());
        expect(panelRect(tester).center.dx, 380);
        expect(es.profiles.resolve('Safari').composerAt, InputPoint.at(Offset(380, home() - 200 - bar()), const Size(800, 600)));
      });
    }

    for (final kind in const [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      testWidgets('a quick ${kind.name} drag on the text leaves the panel where it is', (tester) async {
        await showPicture(tester);
        await openPanel(tester);
        await tester.enterText(fieldFinder, 'some text to select');
        await tester.pump();
        final g = await tester.startGesture(tester.getCenter(fieldFinder), kind: kind);
        for (final m in const [Offset(-10, -100), Offset(-10, -100)]) {
          await g.moveBy(m);
          await tester.pump();
        }
        await g.up();
        await tester.pump();
        await tester.pump(kDoubleTapTimeout);
        expect(panelRect(tester).bottom, home() - bar());
        expect(es.profiles.resolve('Safari').composerAt, isNull);
        expect(text(tester), 'some text to select');
      });
    }

    testWidgets('the picture holds the keys until the panel takes the caret, and gets them back on collapse', (tester) async {
      await showPicture(tester);
      await tester.pump();
      expect(es.pictureFocused, isNotNull);
      await openPanel(tester);
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);
      // A press on the panel (off the text) keeps the keys with it.
      await tester.tapAt(blank(tester));
      await tester.pump();
      await tester.pump();
      expect(es.pictureFocused, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer-panel')), findsNothing);
      expect(es.pictureFocused, isNotNull);
    });

    testWidgets('a touch held still on the text, then moved, moves the panel', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      await tester.enterText(fieldFinder, 'keep');
      await tester.pump();
      final g = await tester.startGesture(tester.getCenter(fieldFinder));
      await tester.pump(const Duration(milliseconds: 400));
      for (final m in const [Offset(-10, -100), Offset(-10, -100)]) {
        await g.moveBy(m);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout);
      expect(panelRect(tester).bottom, home() - 200 - bar());
      expect(panelRect(tester).center.dx, 380);
      expect(text(tester), 'keep');
      expect(fieldFocused(tester), isTrue);
    });

    testWidgets('a two-finger trackpad scroll over the grip does not move the panel', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      var saves = 0;
      es.profiles.addListener(() => saves++);
      final at = tester.getCenter(grip);
      final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await g.panZoomStart(at);
      await tester.pump();
      await g.panZoomUpdate(at, pan: const Offset(0, -100));
      await tester.pump();
      await g.panZoomUpdate(at, pan: const Offset(0, -200));
      await tester.pump();
      await g.panZoomEnd();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout);
      expect(panelRect(tester).bottom, home() - bar());
      expect(saves, 0);
    });

    testWidgets('each app has its own place', (tester) async {
      es.profiles.setComposerAt('Safari', 'Safari', const InputPoint(0.25, 100));
      await showPicture(tester);
      await openPanel(tester);
      expect(panelRect(tester).bottom, 100);
      await openEmbedded(tester, sid: 2, app: 'Notes');
      port.emit(const ReadyEvent(2, 'Notes'));
      port.emit(WindowsEvent(2, [rw(6, 800, 628)]));
      await tester.pump();
      await tester.pump();
      expect(es.currentRemote!.appId, 'Notes');
      // Open or not is the session's (R18): Notes' panel starts closed.
      expect(find.byKey(const Key('composer-panel')), findsNothing);
      await openPanel(tester);
      expect(panelRect(tester).bottom, home() - bar());
      expect(panelRect(tester).center.dx, 400);
    });

    testWidgets('a session switch mid-drag saves for neither app', (tester) async {
      await showPicture(tester);
      await openEmbedded(tester, sid: 2, app: 'Notes');
      port.emit(const ReadyEvent(2, 'Notes'));
      port.emit(WindowsEvent(2, [rw(6, 800, 628)]));
      await tester.pump();
      await openPanel(tester);
      await openEmbedded(tester, sid: 1, app: 'Safari');
      await tester.pump();
      expect(es.currentRemote!.appId, 'Safari');
      await openPanel(tester);
      final g = await tester.startGesture(tester.getCenter(grip));
      await g.moveBy(const Offset(0, -100));
      await tester.pump();
      await openEmbedded(tester, sid: 2, app: 'Notes');
      await tester.pump();
      expect(es.currentRemote!.appId, 'Notes');
      await g.moveBy(const Offset(0, -50));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout);
      expect(es.profiles.resolve('Notes').composerAt, isNull);
      expect(es.profiles.resolve('Safari').composerAt, isNull);
      expect(panelRect(tester).bottom, home() - bar());
    });

    testWidgets('a drag that ends where it started writes nothing', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      var saves = 0;
      es.profiles.addListener(() => saves++);
      await dragGrip(tester, const [Offset(0, -100), Offset(0, 100)]);
      expect(panelRect(tester).bottom, home() - bar());
      expect(saves, 0);
      expect(es.profiles.mine, isEmpty);
    });

    testWidgets('a smaller stage clamps the panel without rewriting its place; it comes back', (tester) async {
      const at = InputPoint(0.5, 500);
      es.profiles.setComposerAt('Safari', 'Safari', at);
      await showPicture(tester);
      await openPanel(tester);
      expect(panelRect(tester).bottom, 500);
      var saves = 0;
      es.profiles.addListener(() => saves++);
      stageSize = const Size(800, 400);
      await tester.pumpWidget(wrap(mainLike()));
      await tester.pump();
      expect(panelRect(tester).bottom - tester.getTopLeft(find.byType(Stage)).dy, 392 - bar());
      stageSize = const Size(800, 600);
      await tester.pumpWidget(wrap(mainLike()));
      await tester.pump();
      expect(panelRect(tester).bottom, 500);
      expect(saves, 0);
      expect(es.profiles.resolve('Safari').composerAt, at);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the panel grows upward; its bottom stays', (tester) async {
      es.profiles.setComposerAt('Safari', 'Safari', const InputPoint(0.5, 400));
      await showPicture(tester);
      await openPanel(tester);
      final before = panelRect(tester);
      es.currentRemote!.composer.setDraft(List.generate(10, (i) => 'line $i').join('\n'));
      await tester.pumpAndSettle();
      final after = panelRect(tester);
      expect(after.height, greaterThan(before.height));
      expect(after.bottom, before.bottom);
    });

    testWidgets('opening the composer takes the caret from the picture', (tester) async {
      await showPicture(tester);
      port.calls.clear();
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);
      expect(port.calls.where((c) => c.$1 == 'picture_focus').map((c) => c.$2), [
        equals({'sid': null}),
      ]);
    });

    testWidgets('Esc collapses and keeps the text (W6); the window Esc never sees it', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(fieldFinder, 'keep');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('composer-panel')), findsNothing);
      expect(escs, 0);
      // Collapse is a copy point: the draft has the text without waiting for the idle copy.
      expect(es.currentRemote!.composer.draft, 'keep');
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      expect(text(tester), 'keep');
    });

    testWidgets('a tap outside the plus menu closes it without reaching A; the next tap does', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump(dockMove); // the text area grows in
      await tester.tap(find.byKey(const Key('composer-plus')));
      await tester.pump();
      final menu = find.byKey(const Key('composer-plus-menu'));
      expect(menu, findsOneWidget);
      port.calls.clear();
      // On the picture, clear of the menu, which now opens rightward from ＋ on the left.
      final spot = tester.getTopRight(find.byType(Picture)) + const Offset(-40, 40);
      expect(tester.getRect(menu).contains(spot), isFalse);
      await tester.tapAt(spot);
      await tester.pump();
      expect(menu, findsNothing);
      expect(port.calls.where((c) => c.$1 == 'mouse'), isEmpty);
      await tester.tapAt(spot);
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'mouse'), isNotEmpty);
    });

    testWidgets('the ＋ menu opens the history and 放进输入框 closes it', (tester) async {
      await showPicture(tester);
      es.history.add({
        'id': '01A',
        'ts': '2026-11-15T09:00:00+09:00',
        'kind': 'sent',
        'from': {'id': 'dev1', 'name': 'x'},
        'host': {'id': '111', 'name': 'mini'},
        'app': {'id': 'Safari', 'name': 'Safari'},
        'session': '111/Safari',
        'text': '回头再看这段',
      });
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump(dockMove); // the text area grows in
      await tester.tap(find.byKey(const Key('composer-plus')));
      await tester.pump();
      await tester.tap(find.text('输入历史'));
      await tester.pump();
      expect(find.byKey(const Key('composer-plus-menu')), findsNothing);
      expect(find.byType(InputHistoryList), findsOneWidget);
      expect(find.byKey(const Key('history-01A')), findsOneWidget); // this session's, by default
      await tester.tap(find.byKey(const Key('history-01A'))); // a click on the row puts it in
      await tester.pumpAndSettle();
      expect(find.byType(InputHistoryList), findsNothing);
      expect(es.currentRemote!.composer.open, isTrue);
      expect(text(tester), contains('回头再看这段'));
    });

    testWidgets('macOS 输入历史 has 加到常用语', (tester) async {
      await showPicture(tester);
      es.history.add({
        'id': '01B',
        'ts': '2026-11-15T09:00:00+09:00',
        'kind': 'sent',
        'from': {'id': 'dev1', 'name': 'x'},
        'host': {'id': '111', 'name': 'mini'},
        'app': {'id': 'Safari', 'name': 'Safari'},
        'session': '111/Safari',
        'text': '常用的一句',
      });
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump(dockMove); // the text area grows in
      await tester.tap(find.byKey(const Key('composer-plus')));
      await tester.pump();
      await tester.tap(find.text('输入历史'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('more-01B')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-phrase-01B')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Esc with the plus menu open closes the panel and the menu', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump(dockMove); // the text area grows in
      await tester.tap(find.byKey(const Key('composer-plus')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('composer-plus-menu')), findsNothing);
      await tester.pumpAndSettle(); // the text area folds away
      expect(find.byKey(const Key('composer-panel')), findsNothing);
    });

    testWidgets('drafts stay with their session across a switch', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.enterText(fieldFinder, 'one');
      final one = es.currentRemote!;

      await openEmbedded(tester, sid: 2, app: 'Notes');
      port.emit(const ReadyEvent(2, 'Notes'));
      port.emit(WindowsEvent(2, [rw(6, 800, 628)]));
      await tester.pump();
      final two = es.currentRemote!;
      expect(two.sid, 2);
      expect(one.composer.draft, 'one'); // copied at the switch, not 1 s later
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      expect(text(tester), isEmpty);
      await tester.enterText(fieldFinder, 'two');

      es.select('111/Safari');
      await tester.pump();
      expect(es.currentRemote, same(one));
      expect(text(tester), 'one');
      expect(two.composer.draft, 'two');
    });

    testWidgets('a clip insert focuses the field, even over a focused picture', (tester) async {
      await showPicture(tester);
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'a')));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);

      // Already open, the picture clicked with the mouse meanwhile (Flutter's focus really moves
      // to it): the insert brings the caret back.
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(tester.getCenter(find.byType(Picture)));
      await g.up();
      await tester.pump();
      expect(es.pictureFocused, 1);
      expect(fieldFocused(tester), isFalse);
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'b')));
      // MainState listens to the port from setUp, outside the test's fake zone: the focus change
      // the event asks for is a real-zone microtask, which pump alone does not run.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);
      expect(text(tester), 'ab');
    });

    testWidgets('Esc and Enter while composing stay with the input method', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump(dockMove); // the text area grows in
      await tester.tap(fieldFinder);
      await tester.pump();
      final m = es.currentRemote!.composer;
      field(tester).controller!.value = const TextEditingValue(
          text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(escs, 0);
      expect(m.open, isTrue);
      expect(text(tester), 'ni');
      expect(callsOf('composer_send'), isEmpty);
      // Not composing: Esc is the panel's (collapse, the text stays), never the window's.
      field(tester).controller!.value =
          const TextEditingValue(text: 'ni', selection: TextSelection.collapsed(offset: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(m.open, isFalse);
      expect(escs, 0);
      expect(m.draft, 'ni');
    });

    testWidgets('a clip insert opens the composer with it', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'from A')));
      await tester.pump();
      expect(find.byType(ComposerPanel), findsOneWidget);
      expect(text(tester), 'from A');
    });

    // R2/R3: records of 111/Safari, given newest first.
    var recId = 0;
    void remember(List<String> newestFirst, {String session = '111/Safari'}) {
      for (final text in newestFirst.reversed) {
        recId++;
        es.history.add({
          'v': 1,
          'id': '01REC${recId.toString().padLeft(4, '0')}',
          'ts': '2026-11-14T10:${recId.toString().padLeft(2, '0')}:00+09:00',
          'kind': 'sent',
          'from': {'id': 'dev1', 'name': 'b'},
          'host': {'id': '111', 'name': 'mini'},
          'app': {'id': 'Safari', 'name': 'Safari'},
          'session': session,
          'run': 'r',
          'projects': <String>[],
          'text': text,
          'blocks': <Object>[],
          'source': 'typed',
        });
      }
    }

    Future<void> liveStage(WidgetTester tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
    }

    // The live session's panel alone, on a FakeEditor.
    Future<FakeEditor> livePanel(WidgetTester tester) async {
      await openEmbedded(tester);
      final ed = FakeEditor();
      final s = es.currentRemote!..composer.open = true;
      await tester.pumpWidget(wrap(SizedBox(
          width: 720, child: ComposerPanel(state: es, session: s, port: port, maxHeight: 300, editor: () => ed))));
      await tester.pump();
      return ed;
    }

    testWidgets('up on an empty editor brings the last one, again the one before, down goes back to empty',
        (tester) async {
      remember(['c', 'b', 'a']);
      await liveStage(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      Future<String> key(LogicalKeyboardKey k) async {
        await tester.sendKeyEvent(k);
        await tester.pump();
        return text(tester);
      }

      expect(await key(LogicalKeyboardKey.arrowUp), 'c');
      expect(await key(LogicalKeyboardKey.arrowUp), 'b');
      expect(await key(LogicalKeyboardKey.arrowDown), 'c');
      expect(await key(LogicalKeyboardKey.arrowDown), '');
      // Down on an empty editor that is not browsing: nothing.
      expect(await key(LogicalKeyboardKey.arrowDown), '');
      // Up to the oldest, and up again stays there.
      expect(await key(LogicalKeyboardKey.arrowUp), 'c');
      expect(await key(LogicalKeyboardKey.arrowUp), 'b');
      expect(await key(LogicalKeyboardKey.arrowUp), 'a');
      expect(await key(LogicalKeyboardKey.arrowUp), 'a');
      expect(await key(LogicalKeyboardKey.arrowDown), 'b');
    });

    testWidgets('a record edited on the way: up and down keep going, and the edit comes back', (tester) async {
      remember(['c', 'b', 'a']);
      final ed = await livePanel(tester);
      final h = ed.handlers!;
      expect(h.onArrow(true), isTrue);
      await tester.pump();
      expect(ed.value, 'c');
      ed.value = 'cx';
      h.onChanged();
      expect(h.onArrow(true), isTrue);
      await tester.pump();
      expect(ed.value, 'b');
      expect(h.onArrow(false), isTrue);
      await tester.pump();
      expect(ed.value, 'cx');
      expect(h.onArrow(false), isTrue);
      await tester.pump();
      expect(ed.value, '');
      expect(h.onArrow(false), isFalse);
    });

    testWidgets('up on a draft keeps it, typed a moment ago or not; down brings it back', (tester) async {
      remember(['c']);
      final ed = await livePanel(tester);
      ed.value = '我写了一半';
      ed.handlers!.onChanged(); // no idle copy yet: the step reads the editor itself
      expect(ed.handlers!.onArrow(true), isTrue);
      await tester.pump();
      expect(ed.value, 'c');
      expect(ed.handlers!.onArrow(false), isTrue);
      await tester.pump();
      expect(ed.value, '我写了一半');
    });

    testWidgets('a collapse while a record is shown loses nothing', (tester) async {
      remember(['c']);
      final ed = await livePanel(tester);
      ed.value = '我写了一半';
      expect(ed.handlers!.onArrow(true), isTrue);
      await tester.pump();
      final s = es.currentRemote!;
      s.composer.collapse();
      await tester.pumpWidget(wrap(const SizedBox()));
      await tester.pump();
      expect(s.composer.draft, 'c');
      final ed2 = FakeEditor();
      s.composer.open = true;
      await tester.pumpWidget(wrap(SizedBox(
          width: 720, child: ComposerPanel(state: es, session: s, port: port, maxHeight: 300, editor: () => ed2))));
      await tester.pump();
      expect(ed2.value, 'c');
      expect(ed2.handlers!.onArrow(false), isTrue);
      await tester.pump();
      expect(ed2.value, '我写了一半');
    });

    testWidgets('up with no history is not taken', (tester) async {
      remember(['elsewhere'], session: '111/Notes');
      final ed = await livePanel(tester);
      expect(ed.handlers!.onArrow(true), isFalse);
      expect(ed.handlers!.onArrow(false), isFalse);
      expect(ed.value, '');
    });

    testWidgets('the hint says ↑ when there is history', (tester) async {
      await liveStage(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      expect(find.text('写给 Safari'), findsOneWidget);
      expect(find.text('写给 Safari · ↑ 上一条'), findsNothing);
      remember(['c']);
      await tester.pump();
      expect(find.text('写给 Safari · ↑ 上一条'), findsOneWidget);
      expect(find.text('写给 Safari'), findsNothing);
    });
  });

  group('stage buttons and the tidy card', () {
    late _Api api;
    late RemoteSession s;
    const stage = Size(1000, 700);
    const long = '嗯那个我门明天下午三点开会';
    final toggle = find.byKey(const Key('composer-open'));
    final card = find.byType(VoiceTidyCard);
    final control = controlHeightFor(TargetPlatform.macOS);

    void platformTest(TargetPlatform p, String name, Future<void> Function(WidgetTester) body) =>
        testWidgets('${p.name}: $name', (tester) async {
          debugDefaultTargetPlatformOverride = p;
          try {
            tester.view.physicalSize = stage;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
    void macTest(String name, Future<void> Function(WidgetTester) body) => platformTest(TargetPlatform.macOS, name, body);

    setUp(() {
      api = _Api();
      es.dispose();
      es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(phraseStrip: false), port: port, llmApi: api);
      es.setLlm(const LlmEndpoint(url: 'localhost:28001', key: 'k'));
    });

    // The live Safari session, on a 1000×700 stage with the composer layer over it.
    Future<void> show(WidgetTester tester, {bool open = false, bool quick = false}) async {
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
          await flush();
        }
      });
      s = es.currentRemote!;
      es.setQuickHidden(term: false, hidden: !quick);
      s.composer.open = open;
      await tester.pumpWidget(wrap(SizedBox(
          key: const Key('stage'),
          width: stage.width,
          height: stage.height,
          child: Stack(children: composerLayer(state: es, session: s, port: port, editor: FlutterEditor.new)))));
      await tester.pumpAndSettle();
    }

    Rect block() => panelPlaceOf(s).value!;
    Rect cardRect(WidgetTester tester) => tester.getRect(card);

    Future<void> tidy(WidgetTester tester) async {
      expect(es.tidyOf(s.sid).begin(long, VoicePick.send), isTrue);
      await tester.pump();
      await tester.pump();
    }

    macTest('输入 stays while open, reads 收起 and is active; a tap folds the text area only, the draft and the quick area stay',
        (tester) async {
      await show(tester, open: true, quick: true);
      s.composer.setDraft('keep me');
      await tester.pump();
      expect(toggle, findsOneWidget);
      expect(find.bySemanticsLabel('收起'), findsOneWidget);
      expect(find.descendant(of: toggle, matching: find.byIcon(Icons.keyboard_hide_outlined)), findsOneWidget);
      final open = tester.widget<OutlinedButton>(find.descendant(of: toggle, matching: find.byType(OutlinedButton)));
      expect(open.style!.side!.resolve({})!.width, 1.5, reason: 'active: the accent border');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(s.composer.open, isFalse);
      expect(s.composer.draft, 'keep me');
      expect(find.byType(ComposerPanel), findsNothing);
      expect(find.byType(KeyBar), findsOneWidget);
      expect(find.bySemanticsLabel('输入'), findsOneWidget);
      expect(find.descendant(of: toggle, matching: find.byIcon(Icons.keyboard_outlined)), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(s.composer.open, isTrue);
      expect(find.byType(ComposerPanel), findsOneWidget);
    });

    macTest('the row rect is the same with the text area open or closed, and with the quick area shown or hidden',
        (tester) async {
      final rects = <Rect>[];
      for (final open in [false, true]) {
        for (final quick in [false, true]) {
          await show(tester, open: open, quick: quick);
          rects.add(tester.getRect(toggle));
        }
      }
      expect(rects.toSet().length, 1, reason: '$rects');
      expect(rects.first.bottom, stage.height - 12);
      expect(rects.first.right, stage.width - 12);
    });

    macTest('desktop default: block bottom is controlHeight + 20 up, centred, not overlapping the row at a 1000-wide stage',
        (tester) async {
      await show(tester, open: true);
      expect(block().bottom, stage.height - (control + 20));
      expect(block().center.dx, stage.width / 2);
      expect(block().bottom, lessThanOrEqualTo(tester.getRect(toggle).top - 8));
    });

    macTest('tidy card: above the block, right-aligned with it; below it with no room above; never off the stage',
        (tester) async {
      await show(tester, open: true);
      await tidy(tester);
      expect(cardRect(tester).right, block().right);
      expect(cardRect(tester).bottom, block().top - 8);
      // The block at the stage's top: no room above, so the card stands under it.
      es.placeComposer(s, const InputPoint(0.5, 0));
      await tester.pumpAndSettle();
      expect(block().top, lessThan(cardRect(tester).height + 16));
      expect(cardRect(tester).top, block().bottom + 8);
      expect(cardRect(tester).right, block().right);
      expect((Offset.zero & stage).inflate(0.01).contains(cardRect(tester).topLeft) &&
          (Offset.zero & stage).inflate(0.01).contains(cardRect(tester).bottomRight), isTrue);
    });

    macTest('tidy card: a quick-only block counts as the block; with none, the card stands in the corner above the row',
        (tester) async {
      await show(tester, quick: true);
      expect(block().height, greaterThan(0));
      await tidy(tester);
      expect(cardRect(tester).bottom, block().top - 8);
      expect(cardRect(tester).right, block().right);
      // Both folded: no block, the corner above the row.
      es.setQuickHidden(term: false, hidden: true);
      await tester.pumpAndSettle();
      expect(block().height, 0);
      expect(cardRect(tester).right, stage.width - 12);
      expect(cardRect(tester).bottom, stage.height - 12 - control - 8);
    });

    platformTest(TargetPlatform.iOS, 'tidy card stands 12 above the stack, which stands above the block', (tester) async {
      await show(tester, quick: true);
      await tidy(tester);
      // Folded, the stack is 语音, 输入 and the 快捷区 toggle on top.
      expect(tester.getRect(toggle).bottom, block().top - 8);
      final top = tester.getRect(find.byKey(const Key('quick-toggle-stack')));
      expect(cardRect(tester).bottom, top.top - 12);
      // Open, the 快捷区 toggle stays on top of 收起 (bar-cmd addendum).
      s.composer.open = true;
      await tester.pumpAndSettle();
      expect(tester.getRect(toggle).bottom, block().top - 8);
      final q = tester.getRect(find.byKey(const Key('quick-toggle-stack')));
      expect(q.bottom, tester.getRect(toggle).top - 12);
      expect(cardRect(tester).bottom, q.top - 12);
    });
  });
}

class _Api extends LlmApi {
  @override
  LlmCall run(LlmEndpoint e, String app, String input,
          {Map<String, String>? vars,
          void Function(String text)? onText,
          Duration firstByte = const Duration(seconds: 10),
          bool think = false}) =>
      LlmCall.manual();
}

/// A local input method whose switch to Chinese ends when the test says so.
class _GatedIme implements LocalIme {
  final calls = <String>[];
  final gate = Completer<String?>();

  @override
  Future<String?> toChinese(String? preferredId) {
    calls.add('toChinese');
    return gate.future;
  }

  @override
  Future<void> toEnglish() async => calls.add('toEnglish');

  @override
  Future<({String id, bool ascii})?> current() async => null;
}

/// A local input method whose every call hangs (ImeIntent gives up on each after 300 ms).
class _HungIme implements LocalIme {
  final calls = <String>[];

  @override
  Future<String?> toChinese(String? preferredId) {
    calls.add('toChinese');
    return Completer<String?>().future;
  }

  @override
  Future<void> toEnglish() {
    calls.add('toEnglish');
    return Completer<void>().future;
  }

  @override
  Future<({String id, bool ascii})?> current() {
    calls.add('current');
    return Completer<({String id, bool ascii})?>().future;
  }
}
