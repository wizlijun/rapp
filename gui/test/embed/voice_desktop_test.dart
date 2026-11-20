import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/geometry.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/voice_desktop.dart';
import 'package:rapp/embed/voice_button.dart' show voiceLanguageHint, voiceSettingsRunner;
import 'package:rapp/embed/voice_input.dart' show VoiceStart;
import 'package:rapp/embed/voice_key_gate.dart';
import 'package:rapp/embed/voice_ring.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';
import 'voice_button_test.dart' show FakeVoice;

class _Api extends LlmApi {
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

String _plain(WidgetTester tester, Finder f) {
  final w = tester.widget<Text>(f);
  return w.data ?? w.textSpan!.toPlainText();
}

void main() {
  late FakeTransport t;
  late _Api api;
  late HubClient hub;
  late FakeSessionPort port;
  late MainState es;
  late Directory tmp;
  late RemoteSession rs;
  late FakeVoice voice;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('voice_desktop_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    port = FakeSessionPort();
    voice = FakeVoice();
    api = _Api();
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, voice: voice, llmApi: api);
    rs = RemoteSession(1, 'Safari');
  });

  tearDown(() {
    rs.dispose();
    es.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> goLive(WidgetTester tester) => tester.runAsync(() async {
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

  Widget layer({double width = 1000, bool reduced = false}) => wrap(
      SizedBox(
          key: const Key('stage'),
          width: width,
          height: 700,
          child: Stack(children: composerLayer(state: es, session: rs, port: port, editor: FlutterEditor.new))),
      disableAnimations: reduced);

  // macOS for the test; the override must be unset before the binding checks its invariants.
  void macTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Future<void> view(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  final hold = find.byKey(const Key('voice-hold'));
  final open = find.byKey(const Key('composer-open'));
  List<Object?> sends() => [for (final c in port.calls) if (c.$1 == 'composer_send') c.$2['pieces']];

  Future<TestGesture> press(WidgetTester tester) async {
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return g;
  }

  test('desktopPick inflates targets by 6', () {
    final cancel = Rect.fromLTWH(110, 40, 60, 24), edit = Rect.fromLTWH(10, 40, 60, 24);
    expect(desktopPick(const Offset(105, 50), cancel, edit), VoicePick.cancel);
    expect(desktopPick(const Offset(103, 50), cancel, edit), VoicePick.send);
    expect(desktopPick(const Offset(73, 50), cancel, edit), VoicePick.edit);
  });

  macTest('the row has 按住说话 rightmost on macOS and Linux', (tester) async {
    await view(tester);
    await tester.pumpWidget(layer());
    expect(hold, findsOneWidget);
    expect(tester.getCenter(hold).dx, greaterThan(tester.getCenter(open).dx));
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(layer(width: 999));
    expect(hold, findsOneWidget);
  });

  // User 2026-11-18: 「其他端同样的按钮透明度都修改 一致。修改为30%透明吧」.
  macTest('the row\'s 还原, 输入 and 按住说话 are 30 % see-through at rest, solid under the mouse or a press', (tester) async {
    await view(tester);
    rs.apply(WindowsEvent(1, [
      RemoteWindow(
          id: 7,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w7',
          rect: const Rect.fromLTWH(0, 0, 100, 100),
          titleBar: 28,
          resizable: true,
          focused: true,
          texture: 7,
          visible: const Rect.fromLTWH(0, 0, 1, 1)),
    ]));
    rs.zoomOf(7).zoomTo(2, const Offset(500, 350), fitRect(const Size(100, 100), const Size(1000, 700)), const Size(1000, 700));
    await tester.pumpWidget(layer());
    final reset = find.byKey(const Key('zoom-reset'));
    double look(Finder f) =>
        tester.widget<AnimatedOpacity>(find.descendant(of: f, matching: find.byType(AnimatedOpacity)).first).opacity;
    for (final f in [reset, open, hold]) {
      expect(look(f), 0.7);
    }
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(open));
    await tester.pump();
    expect(look(open), 1);
    expect(look(reset), 0.7);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(look(open), 0.7);
    final g = await tester.startGesture(tester.getCenter(reset));
    await tester.pump();
    expect(look(reset), 1);
    await g.cancel();
    await tester.pump();
    expect(look(reset), 0.7);
  });

  macTest('press shows 正在听… then send', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    expect(find.text('正在听…'), findsOneWidget);
    expect(find.text('松手 发送'), findsOneWidget);
    voice.partial('你好');
    voice.stopResult = '你好';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(sends(), [
      [
        {'text': '你好'}
      ]
    ]);
    expect(port.calls.last.$1, 'picture_focus');
    expect(port.calls.last.$2['sid'], 1);
    expect(port.calls.any((c) => c.$1 == 'voice_end' && c.$2['sid'] == 1), isTrue);
  });

  macTest('drag onto 取消 then release sends nothing', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    await g.moveTo(tester.getCenter(find.byKey(const Key('voice-cancel'))));
    await tester.pump();
    expect(find.text('松手 取消'), findsOneWidget);
    voice.partial('你好');
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(sends(), isEmpty);
    expect(voice.cancelled, isTrue);
  });

  macTest('drag onto 编辑 opens the panel with the words', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    await g.moveTo(tester.getCenter(find.byKey(const Key('voice-edit'))));
    await tester.pump();
    expect(find.text('松手 改一改再发'), findsOneWidget);
    voice.stopResult = '你好';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(rs.composer.open, isTrue);
    expect(rs.composer.draft, endsWith('你好'));
  });

  macTest('Esc during a mouse hold cancels', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    expect(find.text('正在听…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(voice.cancelled, isTrue);
    expect(find.text('正在听…'), findsNothing);
    await g.up();
    await tester.pump();
  });

  macTest('hotkey start and release send', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    es.voiceKey(1, VoiceKeyPhase.start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('正在听…'), findsOneWidget);
    voice.stopResult = '好的';
    es.voiceKey(1, VoiceKeyPhase.release);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(sends(), hasLength(1));
    expect(find.text('正在听…'), findsNothing);
  });

  macTest('a hotkey start is ignored while the panel is open', (tester) async {
    await view(tester);
    rs.composer.open = true;
    await tester.pumpWidget(layer());
    es.voiceKey(1, VoiceKeyPhase.start);
    await tester.pump();
    expect(voice.starts, 0);
  });

  macTest('disposing during a hotkey hold sends voice_end', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    es.voiceKey(1, VoiceKeyPhase.start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('正在听…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(port.calls.any((c) => c.$1 == 'voice_end' && c.$2['sid'] == 1), isTrue);
    expect(voice.cancelled, isTrue);
  });

  macTest('bubble width', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer(width: 400));
    var g = await press(tester);
    expect(tester.getSize(find.byKey(const Key('voice-bubble'))).width, 368);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(layer(width: 1000));
    g = await press(tester);
    expect(tester.getSize(find.byKey(const Key('voice-bubble'))).width, 480);
    await g.up();
    await tester.pump(const Duration(milliseconds: 200));
  });

  macTest('other buttons fade while holding', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    double opacity() => tester.widget<FadeTransition>(find.ancestor(of: open, matching: find.byType(FadeTransition)).first).opacity.value;
    expect(opacity(), 1);
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(opacity(), 0);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(), 1);
  });

  List<Object?> focuses() => [for (final c in port.calls) if (c.$1 == 'picture_focus') c.$2['sid']];

  macTest('a refused start (denied) leaves the picture focused again', (tester) async {
    await view(tester);
    await goLive(tester);
    voice.startResult = VoiceStart.denied;
    await tester.pumpWidget(layer());
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(focuses().last, 1);
    expect(es.pictureFocused, 1);
    await g.up();
    await tester.pump(const Duration(seconds: 6));
  });

  macTest('a quick click (up before the start resolves) refocuses the picture', (tester) async {
    await view(tester);
    await goLive(tester);
    voice.startGate = Completer<VoiceStart>();
    await tester.pumpWidget(layer());
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    expect(es.pictureFocused, isNull);
    await g.up();
    voice.startGate!.complete(VoiceStart.ok);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(es.pictureFocused, 1);
    expect(focuses().last, 1);
  });

  macTest('a blank 编辑 refocuses the picture; a real one leaves it to the panel', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    var g = await press(tester);
    await g.moveTo(tester.getCenter(find.byKey(const Key('voice-edit'))));
    await tester.pump();
    voice.stopResult = '';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(rs.composer.open, isFalse);
    expect(es.pictureFocused, 1);
    await tester.pump(const Duration(seconds: 3));
  });

  macTest('a mouse press is refused while the recogniser is busy, and blurs nothing', (tester) async {
    await view(tester);
    await goLive(tester);
    es.focusPicture(1);
    voice.startGate = Completer<VoiceStart>();
    await tester.pumpWidget(layer());
    es.voiceKey(1, VoiceKeyPhase.start);
    await tester.pump();
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    expect(voice.starts, 1);
    expect(es.pictureFocused, 1);
    await g.up();
    voice.startGate!.complete(VoiceStart.cancelled);
    await tester.pump();
    // Esc is not swallowed by a press that never opened.
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse);
  });

  macTest('去设置 in the hint can be clicked', (tester) async {
    await view(tester);
    await goLive(tester);
    final ran = <String>[];
    final old = voiceSettingsRunner;
    voiceSettingsRunner = (c, a) async {
      ran.add('$c ${a.join(' ')}');
      return ProcessResult(0, 0, '', '');
    };
    addTearDown(() => voiceSettingsRunner = old);
    voice.startResult = VoiceStart.denied;
    await tester.pumpWidget(layer());
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await g.up();
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-settings')));
    await tester.pump();
    expect(ran, hasLength(1));
    expect(ran.single, contains('Privacy_Microphone'));
    await tester.pump(const Duration(seconds: 6));
  });

  macTest('a first use via 编辑 keeps the language hint for the next send', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    var g = await press(tester);
    await g.moveTo(tester.getCenter(find.byKey(const Key('voice-edit'))));
    await tester.pump();
    voice.stopResult = '你好';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(rs.composer.open, isTrue); // the panel takes the stage row: no hint could paint
    expect(es.prefs.voiceLanguageHintShown, isFalse);
    rs.composer.open = false;
    await tester.pump();
    g = await press(tester);
    voice.stopResult = '好的';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(voiceLanguageHint), findsOneWidget);
    expect(es.prefs.voiceLanguageHintShown, isTrue);
    await tester.pump(const Duration(seconds: 7));
  });

  macTest('on a narrow stage the language hint wraps and 去设置 stays clickable', (tester) async {
    await view(tester);
    await goLive(tester);
    final ran = <String>[];
    final old = voiceSettingsRunner;
    voiceSettingsRunner = (c, a) async {
      ran.add('$c ${a.join(' ')}');
      return ProcessResult(0, 0, '', '');
    };
    addTearDown(() => voiceSettingsRunner = old);
    await tester.pumpWidget(layer(width: 420));
    final g = await press(tester);
    voice.stopResult = '你好';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(voiceLanguageHint), findsOneWidget);
    final stage = tester.getRect(find.byKey(const Key('stage')));
    final hint = tester.getRect(find.byKey(const Key('voice-hint')));
    expect(hint.left, greaterThanOrEqualTo(stage.left));
    expect(hint.right, lessThanOrEqualTo(stage.right));
    final settings = tester.getRect(find.byKey(const Key('voice-settings')));
    expect(settings.right, lessThanOrEqualTo(hint.right));
    await tester.tap(find.byKey(const Key('voice-settings')));
    await tester.pump();
    expect(ran, hasLength(1));
    expect(ran.single, contains('Localization'));
    await tester.pump(const Duration(seconds: 7));
  });

  macTest('the targets carry icons and the button a tooltip', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    expect(find.byType(Tooltip), findsOneWidget);
    await press(tester);
    expect(find.descendant(of: find.byKey(const Key('voice-edit')), matching: find.byIcon(Icons.edit_outlined)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('voice-cancel')), matching: find.byIcon(Icons.close)), findsOneWidget);
  });

  macTest('编辑 draws a cursor after the words', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    voice.partial('你好');
    await g.moveTo(tester.getCenter(find.byKey(const Key('voice-edit'))));
    await tester.pump();
    final bubble = find.byKey(const Key('voice-bubble'));
    expect(find.descendant(of: bubble, matching: find.byType(RichText)).evaluate().any((e) => (e.widget as RichText).text.toPlainText().contains('\uFFFC')), isTrue);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  macTest('the bubble fades out after a release, rising on send; reduced motion is instant', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    var g = await press(tester);
    final bubble = find.byKey(const Key('voice-bubble'));
    final y0 = tester.getTopLeft(bubble).dy;
    voice.stopResult = '你好';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(bubble, findsOneWidget);
    expect(tester.getTopLeft(bubble).dy, lessThan(y0));
    // The rest of the row stays hidden while it goes.
    expect(tester.widget<FadeTransition>(find.ancestor(of: open, matching: find.byType(FadeTransition)).first).opacity.value, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(bubble, findsNothing);

    await tester.pumpWidget(layer(reduced: true));
    g = await press(tester);
    await g.up();
    await tester.pump();
    await tester.pump();
    expect(bubble, findsNothing);
  });

  macTest('a long send stays up where it was and becomes the tidy, which replaces the words, waits, then sends', (tester) async {
    const said = '嗯那个我门明天下午三点开会';
    await view(tester);
    await goLive(tester);
    es.setLlm(const LlmEndpoint(url: 'localhost:28001', key: 'k'));
    await tester.pumpWidget(layer());
    final g = await press(tester);
    voice.partial(said);
    await tester.pump();
    final bubble = find.byKey(const Key('voice-bubble'));
    final at = tester.getRect(bubble);
    voice.stopGate = Completer<String>();
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The stop is still out: the bubble neither fades nor rises.
    expect(bubble, findsOneWidget);
    expect(tester.getRect(bubble).topLeft, at.topLeft);
    voice.stopGate!.complete(said);
    await tester.pump();
    await tester.pump();
    final tidy = find.byKey(const Key('tidy-bubble'));
    expect(bubble, findsNothing);
    expect(tidy, findsOneWidget);
    expect(tester.getRect(tidy).topLeft.dx, closeTo(at.left, 1));
    expect(tester.getRect(tidy).topLeft.dy, closeTo(at.top, 1));
    expect(tester.getSize(tidy).width, closeTo(at.width, 1));
    // The AI's words take the bubble; the heard ones stay under them in one line, to compare (user 2026-11-20).
    api.onText!('我们明天');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_plain(tester, find.byKey(const Key('tidy-body'))), startsWith('我们明天'));
    expect(_plain(tester, find.byKey(const Key('tidy-original'))), contains(said.trim()));
    api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(_plain(tester, find.byKey(const Key('tidy-body'))), '我们明天下午三点开会。');
    expect(find.text('整理好了，马上发送'), findsOneWidget);
    expect(sends(), isEmpty);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(sends(), [
      [
        {'text': '我们明天下午三点开会。'}
      ]
    ]);
    await tester.pumpAndSettle();
    expect(tidy, findsNothing);
  });

  macTest('编辑 while the tidy waits to send opens the panel with the AI text', (tester) async {
    const said = '嗯那个我门明天下午三点开会';
    await view(tester);
    await goLive(tester);
    es.setLlm(const LlmEndpoint(url: 'localhost:28001', key: 'k'));
    await tester.pumpWidget(layer());
    final g = await press(tester);
    voice.partial(said);
    voice.stopResult = said;
    await g.up();
    await tester.pump();
    await tester.pump();
    api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('tidy-edit')));
    await tester.pump(const Duration(seconds: 2));
    expect(sends(), isEmpty);
    // The tidy writes to the state's session (the one the port is for).
    final c = es.remote[1]!.composer;
    expect(c.open, isTrue);
    expect(c.draftText, contains('我们明天下午三点开会。'));
    expect(c.pendingAi?.original, said);
  });
}
