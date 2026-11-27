import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/geometry.dart';
import 'package:rapp/embed/app_profile.dart' show ResolvedProfile;
import 'package:rapp/embed/input_dock.dart' show desktopComposerAt, stackButtonCount;
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/panel_place.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stage_buttons.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late FakeSessionPort port;
  late MainState es;
  late Directory tmp;
  late RemoteSession rs;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('stage_buttons_test');
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
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    rs = RemoteSession(1, 'Safari');
  });

  tearDown(() {
    rs.dispose();
    es.dispose();
    tmp.deleteSync(recursive: true);
  });

  const stage = Size(1000, 700);

  // Every test runs as iOS (one sets macOS itself); the override is cleared before the binding checks it.
  void iosTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Widget layer({SessionPort? p, double keyboard = 0}) => wrap(SizedBox(
      key: const Key('stage'),
      width: stage.width,
      height: stage.height,
      child: Stack(children: composerLayer(state: es, session: rs, port: p ?? port, keyboard: keyboard, editor: FlutterEditor.new))));

  // rs as a text terminal: the state's terminal port owns it, so it is of the terminal kind (its 快捷区 shows).
  FakeTermSessionPort termState() {
    final tport = FakeTermSessionPort()..seed(1);
    es.dispose();
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: tport);
    addTearDown(tport.dispose);
    return tport;
  }

  void big(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  final open = find.byKey(const Key('composer-open'));
  final reset = find.byKey(const Key('zoom-reset'));
  // A rect in stage coordinates (the stage is centred in the test window).
  Rect inStage(WidgetTester tester, Finder f) => tester.getRect(f).shift(-tester.getTopLeft(find.byKey(const Key('stage'))));

  void zoom() => rs.zoomOf(7).zoomTo(2, const Offset(500, 350), fitRect(const Size(100, 100), stage), stage);
  RemoteSession zoomable() {
    final r = RemoteSession(1, 'Safari');
    r.apply(WindowsEvent(1, [
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
          visible: const Rect.fromLTWH(0, 0, 1, 1))
    ]));
    return r;
  }

  iosTest('iOS: 输入 is a 56 square 80 in from the right and 88 up, where a thumb reaches; no text label', (tester) async {
    big(tester);
    await tester.pumpWidget(layer());
    final r = inStage(tester, open);
    expect(r.size, const Size.square(stageButtonSize));
    expect(stage.width - r.right, 80);
    expect(stage.height - r.bottom, 88);
    expect(find.text('输入'), findsNothing);
  });

  // The round buttons' own see-through: the nearest Opacity inside the button.
  double look(WidgetTester tester, Finder f) =>
      tester.widget<AnimatedOpacity>(find.descendant(of: f, matching: find.byType(AnimatedOpacity)).first).opacity;

  iosTest('语音, 输入 and 还原 are one size: stageButtonSize (user 2026-11-18: 「按键能否改成一样大」)', (tester) async {
    big(tester);
    rs.dispose();
    rs = zoomable();
    await tester.pumpWidget(layer());
    zoom();
    await tester.pump();
    expect(stageButtonSize, 56);
    expect(inStage(tester, open).size, const Size.square(stageButtonSize));
    expect(inStage(tester, reset).size, const Size.square(stageButtonSize));
  });

  iosTest('square like the Mac row (user 2026-11-18: 「和 macos 版本一样都改为方的」): the theme corner, no circle', (tester) async {
    big(tester);
    rs.dispose();
    rs = zoomable();
    await tester.pumpWidget(layer());
    zoom();
    await tester.pump();
    final r = RappTokens.of(tester.element(open)).r;
    for (final f in [open, reset]) {
      final b = tester.widget<OutlinedButton>(find.descendant(of: f, matching: find.byType(OutlinedButton)));
      final shape = b.style!.shape!.resolve({});
      expect(shape, isA<RoundedRectangleBorder>());
      expect((shape! as RoundedRectangleBorder).borderRadius, BorderRadius.circular(r));
    }
  });

  iosTest('at rest the stage buttons are 30 % see-through; a finger on one makes it solid until it leaves', (tester) async {
    big(tester);
    await tester.pumpWidget(layer());
    expect(look(tester, open), 0.7);
    final g = await tester.startGesture(tester.getCenter(open));
    await tester.pumpAndSettle();
    expect(look(tester, open), 1);
    // A lift would open the panel and take 输入 away; a cancelled touch ends the press the same way.
    await g.cancel();
    await tester.pumpAndSettle();
    expect(look(tester, open), 0.7);
    expect(rs.composer.open, isFalse);
  });

  test('stackButtonCount counts the toggle open or closed: 语音, 输入, 快捷区, and 还原 while zoomed and closed', () {
    expect(stackButtonCount(rs, voice: true), 3);
    expect(stackButtonCount(rs, voice: false), 2);
    rs.composer.open = true;
    expect(stackButtonCount(rs, voice: true), 3);
    rs.composer.open = false;
    final z = zoomable();
    addTearDown(z.dispose);
    z.zoomOf(7).zoomTo(2, const Offset(500, 350), fitRect(const Size(100, 100), stage), stage);
    expect(stackButtonCount(z, voice: true), 4);
    z.composer.open = true;
    expect(stackButtonCount(z, voice: true), 3, reason: '还原 waits while the text area is open');
    rs.setProfile(const ResolvedProfile(name: 'X', composer: false));
    expect(stackButtonCount(rs, voice: true), 0);
  });

  iosTest('zoomed: 还原 sits 12 above the 快捷区 toggle, which sits 12 above 输入', (tester) async {
    big(tester);
    rs.dispose();
    rs = zoomable();
    await tester.pumpWidget(layer());
    zoom();
    await tester.pump();
    final o = inStage(tester, open);
    final q = inStage(tester, find.byKey(const Key('quick-toggle-stack')));
    final z = inStage(tester, reset);
    expect(o.top - q.bottom, 12);
    expect(q.top - z.bottom, 12);
    expect(z.center.dx, o.center.dx);
  });

  iosTest('macOS keeps the old row', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    big(tester);
    await tester.pumpWidget(layer());
    // Square, as before (the desktop density makes the 48 draw 40).
    expect(tester.getSize(open).aspectRatio, 1);
    expect(tester.getSize(open).width, lessThan(56));
    expect(find.ancestor(of: open, matching: find.byType(Row)), findsWidgets);
    expect(find.byType(StageButtons), findsNothing);
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
    iosTest('${platform.name}: terminal: the 快捷区 stands on the desktop anchor, panel wide; 输入 keeps its corner', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      big(tester);
      final tport = termState();
      await tester.pumpWidget(layer(p: tport));
      await tester.pump();
      final bar = inStage(tester, find.byType(KeyBar));
      expect(bar.width, panelWidth(stage.width));
      expect(bar.center.dx, stage.width / 2);
      expect(stage.height - bar.bottom, desktopComposerAt(controlHeightFor(platform)).dy);
      expect(bar.height, keyBarHeightOf(es, rs));
      expect(stage.height - inStage(tester, open).bottom, 12);
    });

    iosTest('${platform.name}: app session: the toggle beside 输入 while closed; the text area on the anchor while open', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      expect(find.byType(KeyBar), findsNothing);
      expect(find.byKey(const Key('quick-toggle-stack')), findsOneWidget);
      expect(find.byKey(const Key('quick-toggle')), findsNothing);
      final closed = inStage(tester, open);
      rs.composer.open = true;
      await tester.pumpAndSettle();
      expect(find.byType(KeyBar), findsNothing);
      final panel = inStage(tester, find.byType(ComposerPanel));
      expect(stage.height - panel.bottom, desktopComposerAt(controlHeightFor(platform)).dy);
      rs.composer.open = false;
      await tester.pumpAndSettle();
      expect(find.byType(ComposerPanel), findsNothing);
      expect(inStage(tester, open), closed);
    });

  }

  iosTest('dragging 输入 past the middle moves the stack to the left and saves it', (tester) async {
    big(tester);
    await tester.pumpWidget(layer());
    await tester.drag(open, const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(inStage(tester, open).left, 80);
    expect(es.prefs.stageButtonsSide, StageSide.left);
    expect(es.stageSide.value, StageSide.left);
    expect(rs.composer.open, isFalse);
  });

  iosTest('a drag that ends before the middle snaps back right', (tester) async {
    big(tester);
    await tester.pumpWidget(layer());
    await tester.drag(open, const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(stage.width - inStage(tester, open).right, 80);
    expect(es.prefs.stageButtonsSide, StageSide.right);
    expect(rs.composer.open, isFalse);
  });

  iosTest('a wobble under 10 pt is still a tap', (tester) async {
    big(tester);
    await tester.pumpWidget(layer());
    final g = await tester.startGesture(tester.getCenter(open));
    await g.moveBy(const Offset(6, 0));
    await g.up();
    await tester.pumpAndSettle();
    expect(rs.composer.open, isTrue);
    expect(es.prefs.stageButtonsSide, StageSide.right);
  });

  iosTest('left side: the transfer strip is on the right of the stack', (tester) async {
    big(tester);
    es.setStageSide(StageSide.left);
    rs.apply(const TransferStatusEvent(1, '传输中'));
    await tester.pumpWidget(layer());
    final strip = find.text('传输中');
    expect(strip, findsOneWidget);
    expect(tester.getRect(strip).left, greaterThan(tester.getRect(open).right));
    es.setStageSide(StageSide.right);
    await tester.pumpAndSettle();
    expect(tester.getRect(strip).right, lessThan(tester.getRect(open).left));
  });

  iosTest('soft keyboard: the stack rises by the keyboard', (tester) async {
    big(tester);
    await tester.pumpWidget(layer(keyboard: 300));
    expect(stage.height - inStage(tester, open).bottom, 312);
  });

  iosTest('terminal: the stack stands 8 above the 快捷区; with the keyboard up, both ride on it', (tester) async {
    big(tester);
    final tport = termState();
    await tester.pumpWidget(layer(p: tport));
    await tester.pump();
    await tester.pump(); // the block's place reaches the stack a frame later
    // The stack's bottom (its lowest button, 语音 here) stands 8 above the block's top, grip included.
    double stack() => stage.height - inStage(tester, find.byType(StageButtons)).bottom;
    double blockTop() => stage.height - panelPlaceOf(rs).value!.top;
    expect(stage.height - inStage(tester, find.byType(KeyBar)).bottom, 8);
    expect(blockTop(), greaterThan(8 + keyBarHeightOf(es, rs)));
    expect(stack(), math.max(stageButtonsUp, blockTop() + 8));
    await tester.pumpWidget(layer(p: tport, keyboard: 300));
    await tester.pump();
    await tester.pump();
    expect(stage.height - inStage(tester, find.byType(KeyBar)).bottom, 308);
    expect(stack(), blockTop() + 8);
  });

  iosTest('hidden: 输入 fades out and ignores taps; dragging is off', (tester) async {
    big(tester);
    var taps = 0;
    var sides = 0;
    await tester.pumpWidget(wrap(SizedBox(
        key: const Key('stage'),
        width: stage.width,
        height: stage.height,
        child: StageButtons(
          side: StageSide.right,
          onSide: (_) => sides++,
          hidden: true,
          input: RappButtonProbe(onTap: () => taps++),
        ))));
    await tester.pumpAndSettle();
    final fade = tester.widget<FadeTransition>(find.ancestor(of: open, matching: find.byType(FadeTransition)).first);
    expect(fade.opacity.value, 0);
    await tester.tap(open, warnIfMissed: false);
    await tester.drag(open, const Offset(-700, 0), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(sides, 0);
  });

  for (final upright in [false, true]) {
    iosTest('quick sits between input and restore, fades and drags like input (upright: $upright)', (tester) async {
      big(tester);
      var sides = 0;
      Widget stack({bool hidden = false}) => wrap(SizedBox(
          key: const Key('stage'),
          width: stage.width,
          height: stage.height,
          child: StageButtons(
            side: StageSide.right,
            onSide: (_) => sides++,
            hidden: hidden,
            upright: upright,
            voice: probe('v'),
            input: probe('i'),
            quick: probe('q'),
            restore: probe('r'),
          )));
      await tester.pumpWidget(stack());
      Rect r(String k) => inStage(tester, find.byKey(Key(k)));
      if (upright) {
        // Outward from 语音 on the right edge: right to left.
        expect(r('i').left - r('q').right, 12);
        expect(r('q').left - r('r').right, 12);
        expect(r('q').center.dy, r('i').center.dy);
      } else {
        expect(r('q').bottom, r('i').top - 12);
        expect(r('r').bottom, r('q').top - 12);
        expect(r('q').center.dx, r('i').center.dx);
      }
      await tester.drag(find.byKey(const Key('q')), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(sides, 1, reason: 'a drag on quick moves the stack');
      await tester.pumpWidget(stack(hidden: true));
      await tester.pumpAndSettle();
      final fade = tester.widget<FadeTransition>(
          find.ancestor(of: find.byKey(const Key('q')), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, 0);
    });
  }

  iosTest('beside alone: the transfer strip sits 80 from the edge (no empty stack, no gap)', (tester) async {
    big(tester);
    await tester.pumpWidget(wrap(SizedBox(
        key: const Key('stage'),
        width: stage.width,
        height: stage.height,
        child: StageButtons(
          side: StageSide.right,
          onSide: (_) {},
          beside: const [SizedBox(key: Key('strip'), width: 100, height: 40)],
        ))));
    expect(stage.width - inStage(tester, find.byKey(const Key('strip'))).right, 80);
  });

  iosTest('hidden mid-drag: the drag ends, the stack snaps back and stays put', (tester) async {
    big(tester);
    var sides = 0;
    Widget stack(bool hidden) => wrap(SizedBox(
        key: const Key('stage'),
        width: stage.width,
        height: stage.height,
        child: StageButtons(
          side: StageSide.right,
          onSide: (_) => sides++,
          hidden: hidden,
          input: RappButtonProbe(onTap: () {}),
        )));
    await tester.pumpWidget(stack(false));
    final g = await tester.startGesture(tester.getCenter(open));
    await g.moveBy(const Offset(-30, 0));
    await g.moveBy(const Offset(-170, 0));
    await tester.pump();
    expect(stage.width - inStage(tester, open).right, greaterThan(100));
    await tester.pumpWidget(stack(true));
    await g.moveBy(const Offset(-500, 0));
    await g.up();
    await tester.pumpWidget(stack(false));
    await tester.pumpAndSettle();
    expect(stage.width - inStage(tester, open).right, 80);
    expect(sides, 0);
  });
}

/// A plain square standing in for a stage button, keyed [k].
Widget probe(String k) => SizedBox.square(key: Key(k), dimension: 56, child: const ColoredBox(color: Color(0xFF000000)));

/// A stand-in for 输入 that counts taps.
class RappButtonProbe extends StatelessWidget {
  const RappButtonProbe({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(key: const Key('composer-open'), behavior: HitTestBehavior.opaque, onTap: onTap, child: const SizedBox.square(dimension: 56));
}
