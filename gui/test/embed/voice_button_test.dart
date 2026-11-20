import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_float.dart' show gripSize;
import 'package:rapp/embed/composer_model.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/stage_buttons.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/voice_button.dart';
import 'package:rapp/embed/voice_input.dart';
import 'package:rapp/embed/voice_overlay.dart';
import 'package:rapp/embed/voice_ring.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_key_row.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

/// A scripted [VoiceInput]: `start` answers [startResult], `stop` answers [stopResult]. With [startGate] the start
/// stays `starting` until the test completes it; with [stopGate] the stop waits for it.
class FakeVoice extends VoiceInput {
  FakeVoice() : super(channel: const MethodChannel('test/speech'));

  VoiceStart startResult = VoiceStart.ok;
  String stopResult = '';
  bool cancelled = false;
  int starts = 0, stops = 0;
  Completer<VoiceStart>? startGate;
  Completer<String>? stopGate;
  VoicePhase _phase = VoicePhase.idle;
  String _text = '';
  final lv = ValueNotifier<double>(0);

  @override
  VoicePhase get phase => _phase;
  @override
  String get text => _text;
  @override
  ValueListenable<double> get level => lv;

  void partial(String s) {
    _text = s;
    notifyListeners();
  }

  @override
  Future<VoiceStart> start() async {
    starts++;
    _text = '';
    var r = startResult;
    final gate = startGate;
    if (gate != null) {
      _phase = VoicePhase.starting;
      notifyListeners();
      r = await gate.future;
      // Stopped or cancelled meanwhile: stays idle, as VoiceInput does.
      if (_phase != VoicePhase.starting) return r;
    }
    _phase = r == VoiceStart.ok ? VoicePhase.listening : VoicePhase.idle;
    notifyListeners();
    return r;
  }

  @override
  Future<String> stop() async {
    stops++;
    final gate = stopGate;
    if (gate != null && _phase == VoicePhase.listening) {
      _phase = VoicePhase.finishing;
      notifyListeners();
      stopResult = await gate.future;
    }
    _phase = VoicePhase.idle;
    _text = stopResult;
    notifyListeners();
    return stopResult;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    _phase = VoicePhase.idle;
    _text = '';
    notifyListeners();
  }

  @override
  void dispose() {
    lv.dispose();
    super.dispose();
  }
}

void main() {
  late FakeTransport t;
  late HubClient hub;
  late FakeSessionPort port;
  late MainState es;
  late Directory tmp;
  late RemoteSession rs;
  late FakeVoice voice;
  late List<String> haptics;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('voice_button_test');
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
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, voice: voice);
    rs = RemoteSession(1, 'Safari');
  });

  tearDown(() {
    rs.dispose();
    es.dispose();
    tmp.deleteSync(recursive: true);
  });

  const stage = Size(1000, 700);

  void iosTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        haptics = [];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
          if (c.method == 'HapticFeedback.vibrate') haptics.add('${c.arguments}');
          return null;
        });
        try {
          tester.view.physicalSize = const Size(1200, 900);
          tester.view.devicePixelRatio = 1;
          await body(tester);
        } finally {
          tester.view.reset();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Widget layer({RemoteSession? session, bool reduced = false, SessionPort? p, bool keyRow = false, Size size = stage}) => wrap(
      SizedBox(
          key: const Key('stage'),
          width: size.width,
          height: size.height,
          child: Stack(
              children: composerLayer(
                  state: es, session: session ?? rs, port: p ?? port, keyRow: keyRow, editor: FlutterEditor.new))),
      disableAnimations: reduced);

  final hold = find.byKey(const Key('voice-hold'));
  final ringFinder = find.byKey(const Key('voice-ring'));
  final open = find.byKey(const Key('composer-open'));

  Offset origin(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('stage')));
  Rect inStage(WidgetTester tester, Finder f) => tester.getRect(f).shift(-origin(tester));
  VoiceRing ringOf(WidgetTester tester, {bool right = true}) =>
      VoiceRing(stage: stage, thumb: tester.getCenter(hold) - origin(tester), right: right);
  Offset at(WidgetTester tester, VoiceRing r, VoicePick p) => r.probe(p) + origin(tester);
  VoiceRingPainter painter(WidgetTester tester) => tester.widget<CustomPaint>(ringFinder).painter! as VoiceRingPainter;
  double holdOpacity(WidgetTester tester) =>
      tester.widget<Opacity>(find.ancestor(of: hold, matching: find.byType(Opacity)).first).opacity;
  List<Object?> sends() => [for (final c in port.calls) if (c.$1 == 'composer_send') c.$2['pieces']];

  Future<TestGesture> press(WidgetTester tester) async {
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    return g;
  }

  // Release, run the 200 ms release and the 120 ms the stack takes to come back.
  Future<void> lift(WidgetTester tester, TestGesture g) async {
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 120));
  }

  iosTest('hold grows the disc; release in the disc sends the final text', (tester) async {
    rs.composer.draft = 'draft';
    await tester.pumpWidget(layer());
    expect(holdOpacity(tester), 1);
    final g = await press(tester);
    expect(painter(tester).progress, 1);
    // The bands have finished sweeping in by the end of the 240 ms press.
    expect(painter(tester).sweep, 1);
    expect(painter(tester).bands, 1);
    expect(holdOpacity(tester), 0);
    expect(find.text('正在听…'), findsOneWidget);
    expect(find.text('松手 发送'), findsOneWidget);
    voice.partial('你好');
    await tester.pump();
    expect(find.text('你好'), findsOneWidget);
    voice.stopResult = '你好';
    await g.up();
    await tester.pump();
    expect(sends(), [
      [
        {'text': '你好'}
      ]
    ]);
    expect(rs.composer.draft, 'draft');
    await tester.pump(const Duration(milliseconds: 200));
    expect(ringFinder, findsNothing);
    expect(holdOpacity(tester), 1);
  });

  iosTest('slide to 取消: band lights, release sends nothing; back into the disc sends', (tester) async {
    await tester.pumpWidget(layer());
    final r = ringOf(tester);
    var g = await press(tester);
    await g.moveTo(at(tester, r, VoicePick.cancel));
    await tester.pump();
    expect(painter(tester).pick, VoicePick.cancel);
    expect(find.text('松手 取消'), findsOneWidget);
    expect(haptics.where((h) => h == 'HapticFeedbackType.selectionClick').length, 1);
    await lift(tester, g);
    expect(sends(), isEmpty);
    expect(voice.cancelled, isTrue);

    voice.cancelled = false;
    voice.stopResult = '好';
    g = await press(tester);
    await g.moveTo(at(tester, r, VoicePick.cancel));
    await tester.pump();
    await g.moveTo(at(tester, r, VoicePick.send));
    await tester.pump();
    expect(find.text('松手 发送'), findsOneWidget);
    await lift(tester, g);
    expect(sends(), hasLength(1));
    expect(voice.cancelled, isFalse);
  });

  iosTest('panel open: 语音 stays, 8 above the panel on the stack\'s line; a hold there sends, the panel stays', (tester) async {
    rs.composer.open = true;
    await tester.pumpWidget(layer());
    await tester.pump(); // the panel's place reaches the button a frame later
    expect(open, findsNothing);
    expect(hold, findsOneWidget);
    final b = inStage(tester, hold);
    expect(stage.width - b.right, 80);
    expect(inStage(tester, find.byType(ComposerPanel)).top - gripSize.height - b.bottom, 8);
    voice.stopResult = '你好';
    final g = await press(tester);
    await lift(tester, g);
    expect(sends(), [
      [
        {'text': '你好'}
      ]
    ]);
    expect(rs.composer.open, isTrue);
    rs.composer.open = false;
    await tester.pump();
    expect(stage.height - inStage(tester, hold).bottom, 88);
  });

  // A phone held upright (user 2026-11-18: 「竖屏时，键盘在语音按钮靠中间的横排就行了」).
  const upright = Size(393, 852);

  iosTest('语音 is the same size as 输入, and 30 % see-through at rest', (tester) async {
    await tester.pumpWidget(layer(size: upright));
    expect(inStage(tester, hold).size, const Size.square(stageButtonSize));
    expect(inStage(tester, open).size, const Size.square(stageButtonSize));
    final look = tester.widget<AnimatedOpacity>(find.descendant(of: hold, matching: find.byType(AnimatedOpacity)).first);
    expect(look.opacity, 0.7);
  });

  iosTest('portrait: 输入 sits in a row beside 语音, 12 toward the middle; 语音 keeps its 80 / 88', (tester) async {
    await tester.pumpWidget(layer(size: upright));
    final v = inStage(tester, hold);
    final i = inStage(tester, open);
    expect(upright.width - v.right, 80);
    expect(upright.height - v.bottom, 88);
    expect(v.left - i.right, 12);
    expect(i.center.dy, v.center.dy);
  });

  iosTest('portrait, left side: the row mirrors, 输入 on 语音\'s right', (tester) async {
    es.setStageSide(StageSide.left);
    await tester.pumpWidget(layer(size: upright));
    final v = inStage(tester, hold);
    final i = inStage(tester, open);
    expect(v.left, 80);
    expect(i.left - v.right, 12);
    expect(i.center.dy, v.center.dy);
  });

  iosTest('portrait: the transfer strip stands 12 above the row, on its outer edge', (tester) async {
    rs.apply(const TransferStatusEvent(1, '传输中'));
    await tester.pumpWidget(layer(size: upright));
    final v = inStage(tester, hold);
    final strip = inStage(tester, find.text('传输中'));
    expect(strip.top, lessThan(v.top));
    final row = find.ancestor(of: find.text('传输中'), matching: find.byType(Row)).first;
    final r = inStage(tester, row);
    expect(v.top - r.bottom, 12);
    expect(r.right, v.right);
  });

  iosTest('landscape keeps the column: 输入 12 above 语音', (tester) async {
    await tester.pumpWidget(layer());
    final v = inStage(tester, hold);
    final i = inStage(tester, open);
    expect(v.top - i.bottom, 12);
    expect(i.center.dx, v.center.dx);
  });

  iosTest('terminal, key row above the open panel: 语音 stands 8 above the key row', (tester) async {
    final tport = FakeTermSessionPort();
    addTearDown(tport.dispose);
    rs.composer.open = true;
    await tester.pumpWidget(layer(p: tport, keyRow: true));
    await tester.pump();
    final b = inStage(tester, hold);
    expect(inStage(tester, find.byType(TermKeyRow)).top - b.bottom, 8);
    expect(stage.width - b.right, 80);
  });

  iosTest('slide to 编辑: the text goes to the draft end and the composer opens; nothing sent', (tester) async {
    rs.composer.draft = 'x';
    await tester.pumpWidget(layer());
    final r = ringOf(tester);
    final g = await press(tester);
    await g.moveTo(at(tester, r, VoicePick.edit));
    await tester.pump();
    expect(find.text('松手 改一改再发'), findsOneWidget);
    voice.stopResult = '好';
    await g.up();
    await tester.pump();
    expect(rs.composer.draft, 'x\n好');
    expect(rs.composer.open, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(sends(), isEmpty);
  });

  for (final right in [true, false]) {
    iosTest('the hint line sits clear above both bands (right: $right)', (tester) async {
      if (!right) es.setStageSide(StageSide.left);
      await tester.pumpWidget(layer());
      final r = ringOf(tester, right: right);
      final g = await press(tester);
      await g.moveTo(at(tester, r, VoicePick.edit));
      await tester.pump();
      final hint = tester.getRect(find.text('松手 改一改再发'));
      final o = origin(tester);
      for (final p in [VoicePick.edit, VoicePick.cancel]) {
        expect(hint.bottom, lessThanOrEqualTo(r.segment(p).getBounds().top + o.dy), reason: '$p');
      }
      await lift(tester, g);
    });
  }

  iosTest('left side mirrors: 编辑 is still the vertical band', (tester) async {
    es.setStageSide(StageSide.left);
    await tester.pumpWidget(layer());
    final r = ringOf(tester, right: false);
    expect(r.probe(VoicePick.edit).dx, greaterThan(r.thumb.dx));
    final g = await press(tester);
    await g.moveTo(at(tester, r, VoicePick.edit));
    await tester.pump();
    expect(find.text('松手 改一改再发'), findsOneWidget);
    await g.moveTo(at(tester, r, VoicePick.cancel));
    await tester.pump();
    expect(find.text('松手 取消'), findsOneWidget);
    await lift(tester, g);
  });

  iosTest('reduced motion: the disc is there on the first frame', (tester) async {
    await tester.pumpWidget(layer(reduced: true));
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    expect(painter(tester).progress, 1);
    expect(painter(tester).sweep, 1);
    expect(painter(tester).bands, 1);
    expect(holdOpacity(tester), 0);
    await g.up();
    await tester.pump();
    expect(ringFinder, findsNothing);
    expect(holdOpacity(tester), 1);
  });

  iosTest('the level drives the bars', (tester) async {
    await tester.pumpWidget(layer());
    final g = await press(tester);
    voice.lv.value = .8;
    await tester.pump();
    final bars = tester.widget<CustomPaint>(find.byKey(const Key('voice-bars'))).painter! as VoiceBarsPainter;
    expect(bars.level, .8);
    expect(bars.right, isTrue);
    await lift(tester, g);
  });

  iosTest('left hand: the overlay builds the bars mirrored', (tester) async {
    es.setStageSide(StageSide.left);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    final bars = tester.widget<CustomPaint>(find.byKey(const Key('voice-bars'))).painter! as VoiceBarsPainter;
    expect(bars.right, isFalse);
    await lift(tester, g);
  });

  test('the newest bar is at the thumb end: rightmost for the right hand, leftmost for the left', () {
    for (final right in [true, false]) {
      final levels = [...List.filled(23, 0.0), 1.0];
      final rec = ui.PictureRecorder();
      final canvas = _RectCanvas(Canvas(rec));
      VoiceBarsPainter(level: 1, levels: levels, color: const Color(0xff000000), right: right)
          .paint(canvas, const Size(24 * 4 - 2, 20));
      rec.endRecording().dispose();
      final tallest = canvas.rects.reduce((a, b) => b.height > a.height ? b : a);
      expect(tallest.left, right ? 23 * 4.0 : 0.0, reason: 'right: $right');
    }
  });

  iosTest('blank result shows 没听清 for 1.5 s from when it shows (the release end) and sends nothing', (tester) async {
    await tester.pumpWidget(layer());
    final g = await press(tester);
    voice.stopResult = '  ';
    await g.up();
    await tester.pump();
    // The release ends here; the hint shows (the stack fades back in over 120 ms).
    await tester.pump(const Duration(milliseconds: 200));
    expect(ringFinder, findsNothing);
    expect(find.descendant(of: find.byKey(const Key('voice-hint')), matching: find.text('没听清')), findsOneWidget);
    expect(sends(), isEmpty);
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.text('没听清'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('没听清'), findsNothing);
  });

  iosTest('a put-back hint lasts about 2 s from the release end', (tester) async {
    await tester.pumpWidget(layer());
    final g = await press(tester);
    voice.stopResult = '你好';
    // A send that cannot go now: the busy put-back.
    expect(rs.composer.submitText('先发的'), isA<SubmitPieces>());
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('上一段还在发送，已放进输入板'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.text('上一段还在发送，已放进输入板'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('上一段还在发送，已放进输入板'), findsNothing);
  });

  iosTest('a recogniser failure mid-hold shows 没听清; an interruption is silent', (tester) async {
    await tester.pumpWidget(layer());
    var g = await press(tester);
    voice.partial('你好');
    await tester.pump();
    voice.onError!('failed');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(ringFinder, findsNothing);
    expect(find.descendant(of: find.byKey(const Key('voice-hint')), matching: find.text('没听清')), findsOneWidget);
    expect(sends(), isEmpty);
    await g.up();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('voice-hint')), findsNothing);

    g = await press(tester);
    voice.onError!('interrupted');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(ringFinder, findsNothing);
    expect(find.byKey(const Key('voice-hint')), findsNothing);
    expect(sends(), isEmpty);
    await g.up();
    await tester.pump(const Duration(seconds: 2));
  });

  iosTest('a cancel release keeps the last words in the fading bubble, never 正在听…', (tester) async {
    await tester.pumpWidget(layer());
    final r = ringOf(tester);
    final g = await press(tester);
    voice.partial('你好');
    await tester.pump();
    await g.moveTo(at(tester, r, VoicePick.cancel));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(voice.cancelled, isTrue);
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('正在听…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('正在听…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 220));
    expect(ringFinder, findsNothing);
  });

  iosTest('a release the tidy takes keeps the bubble as it is until the stop is back, then hands over its place', (tester) async {
    const said = '这是一段很长很长的语音输入文字';
    final tookAt = <Rect?>[];
    final h = VoiceHold(
      voice: voice,
      send: (_) => null,
      edit: (_) {},
      composer: () => rs.composer,
      tidy: (text, pick, at) {
        tookAt.add(at);
        return true;
      },
      wouldTidy: (_) => true,
    );
    addTearDown(h.dispose);
    await tester.pumpWidget(wrap(SizedBox(width: stage.width, height: stage.height, child: VoiceOverlay(hold: h, voice: voice))));
    unawaited(h.down(const Offset(900, 600), stage, true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    voice.partial(said);
    await tester.pump();
    final words = find.text(said);
    final before = tester.getRect(words);
    double opacity() => tester.widget<Opacity>(find.ancestor(of: words, matching: find.byType(Opacity)).first).opacity;
    voice.stopGate = Completer<String>();
    h.finish(VoicePick.send);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    // The disc and the bands are out; the bubble neither fades nor rises.
    expect(words, findsOneWidget);
    expect(opacity(), 1);
    expect(tester.getRect(words), before);
    expect(painter(tester).scrim, 0);
    voice.stopGate!.complete(said);
    await tester.pump();
    await tester.pump();
    expect(words, findsNothing);
    expect(h.showing, isFalse);
    expect(tookAt.single!.contains(before.center), isTrue);
  });

  iosTest('a session switch while the stop is out puts the words in the original draft', (tester) async {
    rs.composer.draft = 'x';
    final other = RemoteSession(2, 'Notes');
    addTearDown(other.dispose);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    voice.stopGate = Completer<String>();
    await g.up();
    await tester.pump();
    await tester.pumpWidget(layer(session: other));
    voice.stopGate!.complete('你好');
    await tester.pump();
    expect(rs.composer.draft, 'x\n你好');
    expect(other.composer.draft, '');
    expect(sends(), isEmpty);
  });

  iosTest('a session switch while an 编辑 stop is out also keeps the words; blank keeps nothing', (tester) async {
    final other = RemoteSession(2, 'Notes');
    addTearDown(other.dispose);
    await tester.pumpWidget(layer());
    final r = ringOf(tester);
    var g = await press(tester);
    await g.moveTo(at(tester, r, VoicePick.edit));
    await tester.pump();
    voice.stopGate = Completer<String>();
    await g.up();
    await tester.pump();
    await tester.pumpWidget(layer(session: other));
    voice.stopGate!.complete('好');
    await tester.pump();
    expect(rs.composer.draft, '好');
    expect(rs.composer.open, isFalse);

    await tester.pumpWidget(layer());
    await tester.pump(const Duration(milliseconds: 400));
    g = await press(tester);
    voice.stopGate = Completer<String>();
    await g.up();
    await tester.pump();
    await tester.pumpWidget(layer(session: other));
    voice.stopGate!.complete('  ');
    await tester.pump();
    expect(rs.composer.draft, '好');
  });

  iosTest('release while starting: no disc, no hint, no send; the start is stopped', (tester) async {
    for (final reply in [VoiceStart.ok, VoiceStart.unavailable, VoiceStart.cancelled]) {
      voice.startGate = Completer<VoiceStart>();
      voice.stops = 0;
      await tester.pumpWidget(layer());
      final g = await tester.startGesture(tester.getCenter(hold));
      await tester.pump();
      expect(voice.phase, VoicePhase.starting);
      await g.up();
      await tester.pump();
      expect(voice.stops, 1, reason: '$reply');
      voice.startGate!.complete(reply);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(ringFinder, findsNothing, reason: '$reply');
      expect(find.byKey(const Key('voice-hint')), findsNothing, reason: '$reply');
      expect(haptics, isNot(contains('HapticFeedbackType.mediumImpact')), reason: '$reply');
      expect(sends(), isEmpty);
      expect(holdOpacity(tester), 1);
    }
  });

  iosTest('pointer cancel while starting cancels the start', (tester) async {
    voice.startGate = Completer<VoiceStart>();
    await tester.pumpWidget(layer());
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await g.cancel();
    await tester.pump();
    expect(voice.cancelled, isTrue);
    voice.startGate!.complete(VoiceStart.cancelled);
    await tester.pump(const Duration(milliseconds: 240));
    expect(ringFinder, findsNothing);
    expect(find.byKey(const Key('voice-hint')), findsNothing);
  });

  iosTest('start cancelled (overtaken natively): no disc, no hint', (tester) async {
    voice.startResult = VoiceStart.cancelled;
    await tester.pumpWidget(layer());
    final g = await press(tester);
    expect(ringFinder, findsNothing);
    expect(find.byKey(const Key('voice-hint')), findsNothing);
    await lift(tester, g);
    expect(find.byKey(const Key('voice-hint')), findsNothing);
    expect(sends(), isEmpty);
  });

  iosTest('a second pointer on voice-hold, while starting or holding, is ignored', (tester) async {
    voice.startGate = Completer<VoiceStart>();
    voice.stopResult = '好';
    await tester.pumpWidget(layer());
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    // While starting: another finger neither starts again nor ends this one.
    final second = await tester.startGesture(tester.getCenter(hold), pointer: 7);
    await tester.pump();
    await second.up();
    await tester.pump();
    expect(voice.starts, 1);
    expect(voice.stops, 0);
    voice.startGate!.complete(VoiceStart.ok);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(painter(tester).progress, 1);
    // While holding.
    final third = await tester.startGesture(tester.getCenter(hold), pointer: 8);
    await tester.pump();
    await third.moveBy(const Offset(-400, -400));
    await tester.pump();
    await third.up();
    await tester.pump();
    expect(voice.starts, 1);
    expect(voice.stops, 0);
    expect(painter(tester).pick, VoicePick.send);
    await lift(tester, g);
    expect(sends(), hasLength(1));
  });

  iosTest('pointer cancel cancels', (tester) async {
    await tester.pumpWidget(layer());
    voice.stopResult = '你好';
    final g = await press(tester);
    await g.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(sends(), isEmpty);
    expect(voice.cancelled, isTrue);
    expect(ringFinder, findsNothing);
  });

  iosTest('a frozen session keeps the text in the draft with the hint', (tester) async {
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
    port.emit(const ReadyEvent(1, 'Safari'));
    port.emit(const DisconnectedEvent(1, 'connection closed'));
    expect(es.sendBlocked(1), isTrue);
    final s = es.currentRemote!;
    s.composer.draft = 'x';
    await tester.pumpWidget(layer(session: s));
    final g = await press(tester);
    voice.stopResult = '你好';
    await lift(tester, g);
    expect(s.composer.draft, 'x\n你好');
    expect(find.text('连接已断开或正在移动，内容尚未发送'), findsOneWidget);
    expect(sends(), isEmpty);
    expect(s.composer.open, isFalse);
    es.stopReconnectCurrent();
  });

  iosTest('start asked: no disc, no hint', (tester) async {
    voice.startResult = VoiceStart.asked;
    await tester.pumpWidget(layer());
    final g = await press(tester);
    expect(ringFinder, findsNothing);
    expect(find.byKey(const Key('voice-hint')), findsNothing);
    expect(holdOpacity(tester), 1);
    await lift(tester, g);
    expect(find.byKey(const Key('voice-hint')), findsNothing);
    expect(sends(), isEmpty);
  });

  iosTest('start denied: 需要麦克风和语音识别权限 with 去设置 for 4 s', (tester) async {
    voice.startResult = VoiceStart.denied;
    await tester.pumpWidget(layer());
    final g = await press(tester);
    await g.up();
    await tester.pump();
    expect(ringFinder, findsNothing);
    expect(find.text('需要麦克风和语音识别权限'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 3600));
    expect(find.text('去设置'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('需要麦克风和语音识别权限'), findsNothing);
    expect(find.text('去设置'), findsNothing);
  });

  iosTest('start preparing: 正在准备语音识别，请稍后再试', (tester) async {
    voice.startResult = VoiceStart.preparing;
    await tester.pumpWidget(layer());
    final g = await press(tester);
    await g.up();
    await tester.pump();
    expect(ringFinder, findsNothing);
    expect(find.text('正在准备语音识别，请稍后再试'), findsOneWidget);
    expect(find.text('去设置'), findsNothing);
  });

  iosTest('start unavailable: the system-language copy', (tester) async {
    voice.startResult = VoiceStart.unavailable;
    await tester.pumpWidget(layer());
    final g = await press(tester);
    await g.up();
    await tester.pump();
    expect(ringFinder, findsNothing);
    expect(find.text(voiceUnavailable), findsOneWidget);
  });

  iosTest('60 s: acts as release on the current pick', (tester) async {
    await tester.pumpWidget(layer());
    final r = ringOf(tester);
    voice.stopResult = '好';
    var g = await press(tester);
    await g.moveTo(at(tester, r, VoicePick.cancel));
    await tester.pump();
    voice.onMaxLength!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(ringFinder, findsNothing);
    expect(sends(), isEmpty);
    expect(voice.cancelled, isTrue);
    await lift(tester, g);
    expect(sends(), isEmpty);

    g = await press(tester);
    voice.onMaxLength!();
    await tester.pump();
    expect(sends(), hasLength(1));
    await lift(tester, g);
    expect(sends(), hasLength(1));
  });

  iosTest('while holding 输入 is hidden and does nothing', (tester) async {
    await tester.pumpWidget(layer());
    final where = tester.getCenter(open);
    final g = await press(tester);
    await tester.tapAt(where, pointer: 9);
    await tester.pump();
    expect(rs.composer.open, isFalse);
    await lift(tester, g);
    expect(rs.composer.open, isFalse);
  });

  iosTest('press gives a medium haptic', (tester) async {
    await tester.pumpWidget(layer());
    final g = await press(tester);
    expect(haptics, contains('HapticFeedbackType.mediumImpact'));
    await lift(tester, g);
  });

  group('VoiceHold without a pointer', () {
    late List<VoicePick?> ends;
    late int shown;
    var due = true;
    late VoiceHold h;
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      ends = [];
      shown = 0;
      due = true;
      h = VoiceHold(
        voice: voice,
        composer: () => rs.composer,
        send: (text) => sendVoice(state: es, session: rs, port: port, text: text),
        edit: (text) => rs.composer.keep(text),
        onEnd: ends.add,
        languageHintDue: () => due,
        languageHintShown: () => shown++,
      );
    });
    tearDown(() {
      h.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    test('sendVoice keeps AI text with pendingAi when busy', () async {
      const ai = VoiceAi(app: 'dictation', original: '嗯那个我门明天开会', result: '我们明天开会。');
      rs.composer.submitText('还在路上'); // in flight: busy
      final hint = sendVoice(
          state: es, session: rs, port: port, text: '我们明天开会。', voice: const VoiceOrigin(ai: ai));
      await Future<void>.delayed(Duration.zero);
      expect(hint, voiceBusy);
      expect(rs.composer.draft, endsWith('我们明天开会。'));
      expect(rs.composer.pendingAi, ai);
    });

    test('start without a ring holds and finish(send) sends', () async {
      voice.stopResult = '你好';
      await h.start();
      expect(h.holding, isTrue);
      h.finish(VoicePick.send);
      await Future<void>.delayed(Duration.zero);
      expect(sends(), [
        [
          {'text': '你好'}
        ]
      ]);
      expect(ends, [VoicePick.send]);
    });

    test('finish(cancel) drops the words', () async {
      voice.stopResult = '你好';
      await h.start();
      h.finish(VoicePick.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(sends(), isEmpty);
      expect(ends, [VoicePick.cancel]);
    });

    test('finish(edit) puts the words in the draft', () async {
      voice.stopResult = '你好';
      await h.start();
      h.finish(VoicePick.edit);
      await Future<void>.delayed(Duration.zero);
      expect(rs.composer.draft, contains('你好'));
      expect(sends(), isEmpty);
    });

    group('tidy and onPress hooks (voice AI tidy §5.2)', () {
      late List<(String, VoicePick)> took;
      late List<String> sent, edited, order;
      late List<Rect?> tookAt;
      var take = true, would = false;
      VoiceHold hold() => VoiceHold(
            voice: voice,
            composer: () => rs.composer,
            send: (t) {
              sent.add(t);
              return null;
            },
            edit: edited.add,
            onEnd: ends.add,
            languageHintDue: () => true,
            languageHintShown: () => shown++,
            tidy: (t, p, at) {
              took.add((t, p));
              tookAt.add(at);
              return take;
            },
            wouldTidy: (t) => would,
            onPress: () => order.add('press:${voice.starts}'),
          );
      setUp(() {
        took = [];
        tookAt = [];
        would = false;
        sent = [];
        edited = [];
        order = [];
        take = true;
        h.dispose();
        h = hold();
      });

      test('a taken release neither sends nor edits', () async {
        voice.stopResult = '这是一段很长很长的语音输入文字';
        await h.start();
        h.finish(VoicePick.send);
        await Future<void>.delayed(Duration.zero);
        expect(took, [('这是一段很长很长的语音输入文字', VoicePick.send)]);
        expect(sent, isEmpty);
        expect(edited, isEmpty);
        expect(ends, [VoicePick.send]);
        expect(h.hint, isNull);
        expect(shown, 0);
      });

      test('a release a tidy would take hands over: the bubble stays until the stop is back', () async {
        would = true;
        voice.stopGate = Completer<String>();
        await h.start();
        voice.partial('这是一段很长很长的语音输入文字');
        h.bubbleAt = const Rect.fromLTWH(10, 20, 300, 80);
        h.finish(VoicePick.send);
        await Future<void>.delayed(Duration.zero);
        expect(h.handingOver, isTrue);
        voice.stopGate!.complete('这是一段很长很长的语音输入文字');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(h.handingOver, isFalse);
        expect(h.handedOver, isTrue);
        expect(tookAt.single, const Rect.fromLTWH(10, 20, 300, 80));
      });

      test('a release no tidy would take does not hand over', () async {
        take = false;
        voice.stopResult = '你好';
        await h.start();
        h.finish(VoicePick.send);
        expect(h.handingOver, isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(h.handedOver, isFalse);
      });

      test('a declined release sends as before', () async {
        take = false;
        voice.stopResult = '你好';
        await h.start();
        h.finish(VoicePick.send);
        await Future<void>.delayed(Duration.zero);
        expect(sent, ['你好']);
      });

      test('tidy gets the edit pick', () async {
        voice.stopResult = '这是一段很长很长的语音输入文字';
        await h.start();
        h.finish(VoicePick.edit);
        await Future<void>.delayed(Duration.zero);
        expect(took.single.$2, VoicePick.edit);
        expect(edited, isEmpty);
      });

      test('blank text never reaches tidy', () async {
        voice.stopResult = '  ';
        await h.start();
        h.finish(VoicePick.edit);
        await Future<void>.delayed(Duration.zero);
        expect(took, isEmpty);
        expect(h.hint, voiceBlank);
      });

      test('a press calls onPress before start', () async {
        await h.start();
        expect(order, ['press:0']);
        expect(voice.starts, 1);
      });
    });

    test('choose changes the pick without haptics', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (c) async {
        calls.add(c.method);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await h.start();
      var n = 0;
      h.addListener(() => n++);
      h.choose(VoicePick.cancel);
      expect(h.pick, VoicePick.cancel);
      expect(n, 1);
      h.choose(VoicePick.cancel);
      expect(n, 1);
      expect(calls.where((c) => c.startsWith('HapticFeedback')), isEmpty);
    });

    test('a refused start ends with null', () async {
      voice.startResult = VoiceStart.denied;
      await h.start();
      expect(ends, [null]);
      expect(h.hint, voiceDenied);
      expect(h.settings, VoiceSettings.privacy);
    });

    test('language hint once, after the first hold', () async {
      voice.stopResult = '你好';
      await h.start();
      h.finish(VoicePick.send);
      await Future<void>.delayed(Duration.zero);
      expect(h.hint, voiceLanguageHint);
      expect(h.settings, VoiceSettings.language);
      expect(shown, 1);
      due = false;
      h.dispose();
      h = VoiceHold(voice: voice, composer: () => rs.composer, send: (t) => null, edit: (_) {}, languageHintDue: () => due);
      voice.stopResult = '好';
      await h.start();
      h.finish(VoicePick.send);
      await Future<void>.delayed(Duration.zero);
      expect(h.hint, isNull);
    });

    test('a 没听清 release does not show the language hint', () async {
      voice.stopResult = '';
      await h.start();
      h.finish(VoicePick.send);
      await Future<void>.delayed(Duration.zero);
      expect(h.hint, voiceBlank);
      expect(shown, 0);
    });

    test('dispose mid-hold ends with null once', () async {
      await h.start();
      h.dispose();
      expect(ends, [null]);
      h = VoiceHold(voice: voice, composer: () => rs.composer, send: (t) => null, edit: (_) {});
    });

    test('macOS 去设置 opens the pane', () async {
      final ran = <String>[];
      Future<ProcessResult> run(String c, List<String> a) async {
        ran.add('$c ${a.join(' ')}');
        return ProcessResult(0, 0, '', '');
      }
      await openVoiceSettings(VoiceSettings.language, run: run);
      await openVoiceSettings(VoiceSettings.privacy, run: run);
      expect(ran, [
        'open x-apple.systempreferences:com.apple.Localization-Settings.extension',
        'open x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
      ]);
    });
  });

  iosTest('macOS: the Mac row button, not the 64 round one', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(layer());
    expect(open, findsOneWidget);
    expect(tester.getSize(hold).width, lessThan(64));
    expect(ringFinder, findsNothing);
  });

  for (final right in [true, false]) {
    iosTest('each band is drawn on the side pick maps it to (right: $right), in the painter the overlay builds', (tester) async {
      if (!right) es.setStageSide(StageSide.left);
      await tester.pumpWidget(layer());
      final g = await press(tester);
      final p = painter(tester);
      expect(p.sweep, 1);
      final ring = p.ring;
      expect(ring.right, right);
      for (final which in [VoicePick.edit, VoicePick.cancel]) {
        final metric = p.bandPath(which).computeMetrics().first;
        // Along the outer arc, near the far end.
        final far = metric.getTangentForOffset((ring.inner + ring.band) * 19 * math.pi / 180 * .9)!.position;
        final v = far - ring.centre;
        final pushed = ring.centre + v / v.distance * (ring.r + 5);
        expect(ring.pick(pushed), which);
      }
      await lift(tester, g);
    });
  }

  iosTest('the disc grows from the square 语音 (its size and theme corner) into the round disc', (tester) async {
    await tester.pumpWidget(layer());
    final square = tester.getRect(hold);
    final g = await press(tester);
    final p = painter(tester);
    VoiceRingPainter at(double progress) =>
        VoiceRingPainter(ring: p.ring, pick: p.pick, progress: progress, tokens: p.tokens);
    final start = at(0).disc;
    expect(start.outerRect.size, square.size);
    expect(start.outerRect.center, p.ring.thumb);
    expect(start.tlRadiusX, p.tokens.r);
    final end = at(1).disc;
    expect(end.outerRect, Rect.fromCircle(center: p.ring.centre, radius: p.ring.r));
    expect(end.tlRadiusX, p.ring.r);
    await lift(tester, g);
  });

  iosTest('release mid-press: the bands go out from where they were, never jumping to the full sweep', (tester) async {
    await tester.pumpWidget(layer());
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final before = painter(tester);
    expect(before.sweep, closeTo(.5, .01));
    expect(before.bands, closeTo(.5, .01));
    await g.up();
    await tester.pump();
    expect(painter(tester).sweep, closeTo(before.sweep, 1e-9));
    expect(painter(tester).bands, lessThanOrEqualTo(before.bands));
    await tester.pump(const Duration(milliseconds: 50));
    expect(painter(tester).sweep, closeTo(before.sweep, 1e-9));
    expect(painter(tester).bands, closeTo(before.bands / 2, .01));
    await tester.pump(const Duration(milliseconds: 60));
    expect(painter(tester).bands, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(ringFinder, findsNothing);
  });
}

/// Records the rects drawn, passing everything on.
class _RectCanvas implements Canvas {
  _RectCanvas(this._inner);
  final Canvas _inner;
  final rects = <Rect>[];

  @override
  void drawRect(Rect rect, Paint paint) {
    rects.add(rect);
    _inner.drawRect(rect, paint);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
