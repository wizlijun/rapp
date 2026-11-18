import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/geometry.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stage_buttons.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_key_row.dart';
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

  Widget layer({SessionPort? p, bool keyRow = false, double keyboard = 0}) => wrap(SizedBox(
      key: const Key('stage'),
      width: stage.width,
      height: stage.height,
      child: Stack(children: composerLayer(state: es, session: rs, port: p ?? port, keyRow: keyRow, keyboard: keyboard, editor: FlutterEditor.new))));

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

  iosTest('zoomed: 还原 sits 12 above 输入', (tester) async {
    big(tester);
    rs.dispose();
    rs = zoomable();
    await tester.pumpWidget(layer());
    zoom();
    await tester.pump();
    final o = inStage(tester, open);
    final z = inStage(tester, reset);
    expect(o.top - z.bottom, 12);
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

  iosTest('terminal key row on: the stack keeps its 88 (above the key row); with the keyboard up, 8 above the row', (tester) async {
    big(tester);
    final tport = FakeTermSessionPort();
    addTearDown(tport.dispose);
    await tester.pumpWidget(layer(p: tport, keyRow: true));
    expect(stage.height - inStage(tester, open).bottom, 88);
    await tester.pumpWidget(layer(p: tport, keyRow: true, keyboard: 300));
    expect(stage.height - inStage(tester, open).bottom, 300 + keyRowBottom + keyRowKeySize.height + 8);
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

/// A stand-in for 输入 that counts taps.
class RappButtonProbe extends StatelessWidget {
  const RappButtonProbe({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(key: const Key('composer-open'), behavior: HitTestBehavior.opaque, onTap: onTap, child: const SizedBox.square(dimension: 56));
}
