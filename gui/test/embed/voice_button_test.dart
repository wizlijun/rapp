import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/voice_input.dart';
import 'package:rapp/embed/voice_overlay.dart';
import 'package:rapp/embed/voice_ring.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

/// A scripted [VoiceInput]: `start` answers [startResult], `stop` answers [stopResult].
class FakeVoice extends VoiceInput {
  FakeVoice() : super(channel: const MethodChannel('test/speech'));

  VoiceStart startResult = VoiceStart.ok;
  String stopResult = '';
  bool cancelled = false;
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
    _text = '';
    _phase = startResult == VoiceStart.ok ? VoicePhase.listening : VoicePhase.idle;
    notifyListeners();
    return startResult;
  }

  @override
  Future<String> stop() async {
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

  Widget layer({RemoteSession? session, bool reduced = false}) => wrap(
      SizedBox(
          key: const Key('stage'),
          width: stage.width,
          height: stage.height,
          child: Stack(children: composerLayer(state: es, session: session ?? rs, port: port, editor: FlutterEditor.new))),
      disableAnimations: reduced);

  final hold = find.byKey(const Key('voice-hold'));
  final ringFinder = find.byKey(const Key('voice-ring'));
  final open = find.byKey(const Key('composer-open'));

  Offset origin(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('stage')));
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
    await lift(tester, g);
  });

  iosTest('blank result shows 没听清 for 1.5 s and sends nothing', (tester) async {
    await tester.pumpWidget(layer());
    final g = await press(tester);
    voice.stopResult = '  ';
    await lift(tester, g);
    expect(ringFinder, findsNothing);
    expect(find.descendant(of: find.byKey(const Key('voice-hint')), matching: find.text('没听清')), findsOneWidget);
    expect(sends(), isEmpty);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('没听清'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('没听清'), findsNothing);
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

  iosTest('start unavailable: 这台设备不能识别语音', (tester) async {
    voice.startResult = VoiceStart.unavailable;
    await tester.pumpWidget(layer());
    final g = await press(tester);
    await g.up();
    await tester.pump();
    expect(ringFinder, findsNothing);
    expect(find.text('这台设备不能识别语音'), findsOneWidget);
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

  iosTest('macOS: no voice button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(layer());
    expect(open, findsOneWidget);
    expect(hold, findsNothing);
  });

  test('each band is drawn on the side pick maps it to, on both hands', () {
    for (final right in [true, false]) {
      final ring = VoiceRing(stage: stage, thumb: Offset(right ? 956 : 44, 656), right: right);
      final p = VoiceRingPainter(ring: ring, pick: VoicePick.send, progress: 1, tokens: tokensFor(RappTheme.matrix));
      for (final which in [VoicePick.edit, VoicePick.cancel]) {
        final metric = p.bandPath(which).computeMetrics().first;
        // Along the outer arc, near the far end.
        final far = metric.getTangentForOffset((ring.inner + ring.band) * 19 * math.pi / 180 * .9)!.position;
        final v = far - ring.centre;
        final pushed = ring.centre + v / v.distance * (ring.r + 5);
        expect(ring.pick(pushed), which, reason: 'right: $right');
      }
    }
  });
}
