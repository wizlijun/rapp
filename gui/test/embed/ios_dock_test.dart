// iOS's dock (iOS input toggle, Task 5): the soft keyboard, the key bar, the writing panel and the stage's button stack
// move as one; the bar stands on the keyboard, the panel 8 above the bar, the stack 8 above the panel.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_float.dart' show gripSize;
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/ios_dock.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stage_buttons.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart' show keyboardLift;
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';

void main() {
  late Directory tmp;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  late RemoteSession app, tsess, tapp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ios_dock_test');
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
    term.seed(2);
    app = RemoteSession(1, 'Safari');
    tsess = RemoteSession(2, 'term');
    tapp = RemoteSession(3, 'Terminal', appId: 'com.apple.Terminal');
  });

  tearDown(() {
    for (final r in [app, tsess, tapp]) {
      r.dispose();
    }
    s.dispose();
    term.dispose();
    tmp.deleteSync(recursive: true);
  });

  const stage = Size(1000, 700);
  const frame = Duration(milliseconds: 16);

  void iosTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          tester.view.physicalSize = stage;
          tester.view.devicePixelRatio = 1;
          await body(tester);
        } finally {
          tester.view.reset();
          debugDefaultTargetPlatformOverride = null;
        }
      });

  SessionPort portOf(RemoteSession rs) => rs == tsess ? term : port;

  // The stage fills the view, so the keyboard ([tester.view.viewInsets]) reaches over its bottom as on the device.
  Widget layer(RemoteSession rs, {bool reduced = false}) => MaterialApp(
        theme: themeDataFor(RappTheme.matrix),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: c!,
        ),
        home: Material(
          child: Builder(
            builder: (context) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: const Key('stage'),
                width: stage.width,
                height: stage.height,
                child: Stack(
                  children: composerLayer(
                    state: s,
                    session: rs,
                    port: portOf(rs),
                    keyboard: keyboardLift(MediaQuery.of(context), fullscreen: true),
                    editor: FlutterEditor.new,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  void keyboard(WidgetTester tester, double k) => tester.view.viewInsets = FakeViewPadding(bottom: k);

  final panel = find.byKey(const Key('composer-panel'));
  final toggle = find.byKey(const Key('composer-open'));
  final bar = find.byType(KeyBar);

  // Up off the stage's bottom.
  double bottomOf(WidgetTester tester, Finder f) => stage.height - tester.getRect(f).bottom;
  double topOf(WidgetTester tester, Finder f) => stage.height - tester.getRect(f).top;
  double barH(RemoteSession rs) => keyBarHeightOf(s, rs, stage.width);
  // An app's panel floats with its grip on top: the stack clears the grip.
  double grip(RemoteSession rs) => rs == tsess ? 0 : gripSize.height;
  double fade(WidgetTester tester) => tester.widget<Opacity>(find.byKey(const Key('dock-panel-fade'))).opacity;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(); // the panel's place reaches the stack a frame later
  }

  Future<void> openOn(WidgetTester tester, RemoteSession rs) async {
    await tester.pumpWidget(layer(rs));
    rs.composer.open = true;
    await settle(tester);
    expect(panel, findsOneWidget);
  }

  test('keyBarWhenClosed: a terminal session or a terminal app, not another app', () {
    expect(keyBarWhenClosed(tsess, term), isTrue);
    expect(keyBarWhenClosed(tapp, port), isTrue);
    expect(keyBarWhenClosed(app, port), isFalse);
  });

  for (final which in ['terminal', 'Safari']) {
    RemoteSession rsOf() => which == 'terminal' ? tsess : app;

    iosTest('$which: open with keyboard 300: bar bottom 300, panel bottom 300+bar+8, stack 8 above panel', (tester) async {
      keyboard(tester, 300);
      final rs = rsOf();
      expect(barH(rs), 54, reason: 'one row at width 1000');
      await openOn(tester, rs);
      expect(bar, findsOneWidget);
      expect(tester.getSize(bar).width, stage.width);
      expect(bottomOf(tester, bar), 300);
      expect(bottomOf(tester, panel), 300 + barH(rs) + 8);
      expect(bottomOf(tester, toggle), topOf(tester, panel) + grip(rs) + 8);
    });

    iosTest('$which: open, no keyboard: bar at 0, panel 8 above it (G5)', (tester) async {
      final rs = rsOf();
      expect(barH(rs), 54, reason: 'one row at width 1000');
      await openOn(tester, rs);
      expect(bottomOf(tester, bar), 0);
      expect(topOf(tester, bar), barH(rs));
      expect(bottomOf(tester, panel), barH(rs) + 8);
      expect(bottomOf(tester, toggle), topOf(tester, panel) + grip(rs) + 8);
    });
  }

  iosTest('open, no keyboard: the panel rises 340ms from below while it fades in (G3)', (tester) async {
    await tester.pumpWidget(layer(tsess));
    tsess.composer.open = true;
    await tester.pump();
    await tester.pump(); // the panel's place, a frame behind
    var last = -double.infinity;
    var t = Duration.zero;
    while (t < const Duration(milliseconds: 100)) {
      await tester.pump(frame);
      t += frame;
      final p = bottomOf(tester, panel);
      expect(p, greaterThanOrEqualTo(last), reason: 'the panel only goes up, at $t');
      last = p;
    }
    final rest = barH(tsess) + 8;
    expect(fade(tester), lessThan(1), reason: 'still fading in at $t');
    expect(fade(tester), greaterThan(0));
    expect(bottomOf(tester, panel), lessThan(rest - 1), reason: 'still rising at $t');
    await settle(tester);
    expect(fade(tester), 1);
    expect(bottomOf(tester, panel), rest);
  });

  iosTest('open, keyboard rising 0→300 over frames: the stack never goes down and never jumps by more than one '
      'frame\'s step', (tester) async {
    await tester.pumpWidget(layer(tsess));
    final b = barH(tsess);
    var stack = bottomOf(tester, toggle);
    tsess.composer.open = true;
    await tester.pump();
    double? panelHeight;
    for (var i = 1; i <= 25; i++) {
      final k = 300.0 * math.min(1.0, i / 15);
      keyboard(tester, k);
      await tester.pump(frame);
      panelHeight ??= tester.getSize(panel).height;
      final now = bottomOf(tester, toggle);
      // easeOutCubic's steepest slope is 3 (of the whole way, the panel's rise in it), plus the keyboard's own step.
      final step = 3 * frame.inMicroseconds / 340000 * (300 + b + 8 + panelHeight + 8 + 8) + 20 + 1;
      expect(now, greaterThanOrEqualTo(stack - 0.01), reason: 'frame $i');
      expect(now - stack, lessThanOrEqualTo(step), reason: 'frame $i');
      stack = now;
    }
    await settle(tester);
    expect(bottomOf(tester, panel), 300 + b + 8);
    expect(bottomOf(tester, toggle), topOf(tester, panel) + 8);
    expect(fade(tester), 1);
  });

  iosTest('close then open in its last 100 ms: the panel fades back in from where it was, no snap to opaque',
      (tester) async {
    await openOn(tester, tsess);
    tsess.composer.collapse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 290));
    final o = fade(tester);
    expect(o, lessThan(1));
    tsess.composer.open = true;
    await tester.pump();
    expect(fade(tester), closeTo(o, 0.05));
    await tester.pump(frame);
    expect(fade(tester), lessThan(1));
    expect(fade(tester), greaterThanOrEqualTo(o - 0.01));
    await settle(tester);
    expect(fade(tester), 1);
    expect(bottomOf(tester, panel), barH(tsess) + 8);
  });

  iosTest('close, keyboard falling 300→0 over frames: panel still mounted and its bottom follows keyboard+bar each '
      'frame; unmounted after the fade', (tester) async {
    keyboard(tester, 300);
    await openOn(tester, tsess);
    final b = barH(tsess);
    tsess.composer.collapse();
    for (var i = 1; i <= 15; i++) {
      final k = 300 * (1 - i / 15);
      keyboard(tester, k);
      await tester.pump(frame);
      expect(panel, findsOneWidget, reason: 'frame $i');
      expect(bottomOf(tester, panel), closeTo(k + b + 8, 0.01), reason: 'frame $i');
      expect(bottomOf(tester, bar), closeTo(k, 0.01), reason: 'the bar stays on the keyboard, frame $i');
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(panel, findsNothing);
    expect(bar, findsOneWidget, reason: 'a terminal keeps its bar closed');
  });

  iosTest('close with no keyboard: panel slides down 340ms, stack bottom never below its closed value and never jumps '
      'by more than one frame\'s step (Review Focus 3)', (tester) async {
    await openOn(tester, tsess);
    final b = barH(tsess);
    final closed = math.max(stageButtonsUp, b + 8);
    final panelBottom = bottomOf(tester, panel);
    final panelHeight = tester.getSize(panel).height;
    var stack = bottomOf(tester, toggle);
    // easeOutCubic's steepest slope is 3: one frame moves the stack at most that much of its whole way, plus the
    // panel's own drop it follows.
    final step = 3 * frame.inMicroseconds / 340000 * (stack - closed + panelHeight + 8) + 1;
    tsess.composer.collapse();
    var lastPanel = panelBottom;
    var t = Duration.zero;
    while (t < const Duration(milliseconds: 320)) {
      await tester.pump(frame);
      t += frame;
      expect(panel, findsOneWidget, reason: 'at $t');
      final p = bottomOf(tester, panel);
      expect(p, lessThanOrEqualTo(lastPanel), reason: 'the panel only goes down, at $t');
      lastPanel = p;
      final now = bottomOf(tester, toggle);
      expect(now, greaterThanOrEqualTo(closed - 0.01), reason: 'at $t');
      expect((now - stack).abs(), lessThanOrEqualTo(step), reason: 'at $t');
      stack = now;
      if (t == const Duration(milliseconds: 160)) {
        expect(p, lessThan(panelBottom - 20), reason: 'half way it is well on its way down');
        expect(fade(tester), 1, reason: 'the fade is only the last 100 ms');
      }
    }
    expect(fade(tester), lessThan(1));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(panel, findsNothing);
    expect(bottomOf(tester, toggle), closed);
  });

  iosTest('close then open within 200ms: one ComposerPanel, same State, draft intact (Review Focus 4)', (tester) async {
    await openOn(tester, app);
    await tester.enterText(find.byKey(const Key('composer-field')), 'hello');
    await tester.pump();
    final before = tester.state(find.byType(ComposerPanel));
    final at = bottomOf(tester, panel);
    app.composer.collapse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(panel, findsOneWidget);
    app.composer.open = true;
    await settle(tester);
    expect(find.byType(ComposerPanel), findsOneWidget);
    expect(identical(tester.state(find.byType(ComposerPanel)), before), isTrue);
    expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, 'hello');
    expect(bottomOf(tester, panel), at);
    expect(fade(tester), 1);
  });

  iosTest('closed terminal session: KeyBar shown, stack at max(88, 54+8)', (tester) async {
    await tester.pumpWidget(layer(tsess));
    await tester.pump();
    expect(barH(tsess), 54);
    expect(bar, findsOneWidget);
    expect(bottomOf(tester, bar), 0);
    expect(bottomOf(tester, toggle), math.max(88, 54 + 8));
    expect(panel, findsNothing);
  });

  iosTest('closed terminal session, keyboard 300: the stack on the bar, 12 above it', (tester) async {
    keyboard(tester, 300);
    await tester.pumpWidget(layer(tsess));
    await tester.pump();
    expect(bottomOf(tester, bar), 300);
    expect(bottomOf(tester, toggle), 300 + 54 + stageButtonsEdge);
  });

  iosTest('closed Safari session: no KeyBar, stack at 88', (tester) async {
    await tester.pumpWidget(layer(app));
    await tester.pump();
    expect(bar, findsNothing);
    expect(bottomOf(tester, toggle), 88);
  });

  iosTest('closed com.apple.Terminal session: KeyBar shown', (tester) async {
    await tester.pumpWidget(layer(tapp));
    await tester.pump();
    expect(bar, findsOneWidget);
    expect(bottomOf(tester, bar), 0);
    expect(bottomOf(tester, toggle), 88);
  });

  iosTest('Safari closing: its bar goes with the panel', (tester) async {
    await openOn(tester, app);
    expect(bar, findsOneWidget);
    app.composer.collapse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(bar, findsOneWidget, reason: 'still on its way out');
    await tester.pump(const Duration(milliseconds: 300));
    expect(bar, findsNothing);
  });

  iosTest('disableAnimations: open/close lands in one frame', (tester) async {
    await tester.pumpWidget(layer(tsess, reduced: true));
    tsess.composer.open = true;
    await tester.pump();
    expect(panel, findsOneWidget);
    expect(bottomOf(tester, panel), barH(tsess) + 8);
    await tester.pump(); // the stack follows the panel's place a frame later
    expect(bottomOf(tester, toggle), topOf(tester, panel) + 8);
    tsess.composer.collapse();
    await tester.pump();
    expect(panel, findsNothing);
    expect(bottomOf(tester, toggle), 88);
  });

  iosTest('输入 and 收起 are one element: the icon turns over, both icons mid-switch (R12)', (tester) async {
    await tester.pumpWidget(layer(app));
    await tester.pump();
    final closed = tester.element(toggle);
    app.composer.open = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(identical(tester.element(toggle), closed), isTrue);
    expect(find.descendant(of: toggle, matching: find.byIcon(Icons.keyboard_outlined)), findsOneWidget);
    expect(find.descendant(of: toggle, matching: find.byIcon(Icons.keyboard_hide_outlined)), findsOneWidget);
    await settle(tester);
    expect(find.descendant(of: toggle, matching: find.byIcon(Icons.keyboard_outlined)), findsNothing);
    app.composer.collapse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(identical(tester.element(toggle), closed), isTrue);
    expect(find.descendant(of: toggle, matching: find.byIcon(Icons.keyboard_outlined)), findsOneWidget);
    expect(find.descendant(of: toggle, matching: find.byIcon(Icons.keyboard_hide_outlined)), findsOneWidget);
  });

  iosTest('terminal panel: pull on its border 80 -> collapsed (G4)', (tester) async {
    await openOn(tester, tsess);
    final r = tester.getRect(panel);
    final g = await tester.startGesture(r.topLeft + const Offset(3, 3));
    await g.moveBy(const Offset(0, 40));
    await tester.pump(frame);
    await g.moveBy(const Offset(0, 40));
    await tester.pump(frame);
    expect(tsess.composer.open, isTrue);
    await g.up();
    await tester.pump();
    expect(tsess.composer.open, isFalse);
    await settle(tester);
    expect(panel, findsNothing);
  });

  iosTest('terminal panel: pull 40 springs back, stack follows the pull 1:1', (tester) async {
    await openOn(tester, tsess);
    final r = tester.getRect(panel);
    final stack = bottomOf(tester, toggle);
    final g = await tester.startGesture(r.topLeft + const Offset(3, 3));
    await g.moveBy(const Offset(0, 20));
    await tester.pump(frame);
    await g.moveBy(const Offset(0, 20));
    await tester.pump(frame);
    await tester.pump(frame);
    expect(tester.getRect(panel).top, closeTo(r.top + 40, 0.5));
    expect(bottomOf(tester, toggle), closeTo(stack - 40, 0.5));
    await g.up();
    await tester.pump();
    expect(tsess.composer.open, isTrue);
    await settle(tester);
    expect(tester.getRect(panel).top, closeTo(r.top, 0.5));
    expect(bottomOf(tester, toggle), closeTo(stack, 0.5));
  });

  iosTest('app panel at lowest: pull 40 slowly, the stack follows 1:1 and springs back with it', (tester) async {
    await openOn(tester, app);
    final grip = find.byKey(const Key('composer-grip'));
    final g0 = tester.getCenter(grip);
    final stack = bottomOf(tester, toggle);
    final g = await tester.startGesture(g0);
    for (var i = 1; i <= 2; i++) {
      await g.moveBy(const Offset(0, 20), timeStamp: Duration(milliseconds: 300 * i));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.pump();
    expect(tester.getCenter(grip).dy, closeTo(g0.dy + 40, 0.5));
    expect(bottomOf(tester, toggle), closeTo(stack - 40, 0.5));
    await g.up(timeStamp: const Duration(milliseconds: 600));
    await settle(tester);
    expect(app.composer.open, isTrue);
    expect(tester.getCenter(grip).dy, closeTo(g0.dy, 0.5));
    expect(bottomOf(tester, toggle), closeTo(stack, 0.5));
  });

  for (final which in ['terminal', 'Safari']) {
    iosTest('$which: reopened during a pull-close, the panel springs back; a 10pt drag does not collapse', (tester) async {
      final rs = which == 'terminal' ? tsess : app;
      await openOn(tester, rs);
      final top0 = tester.getRect(panel).top;
      final from = which == 'terminal' ? tester.getRect(panel).topLeft + const Offset(3, 3) : tester.getCenter(find.byKey(const Key('composer-grip')));
      final g = await tester.startGesture(from);
      await g.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 16));
      await tester.pump(frame);
      await g.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 32));
      await tester.pump(frame);
      await g.up(timeStamp: const Duration(milliseconds: 32));
      await tester.pump();
      expect(rs.composer.open, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      rs.composer.open = true;
      await settle(tester);
      expect(tester.getRect(panel).top, closeTo(top0, 0.5));
      final g2 = await tester.startGesture(from);
      await g2.moveBy(const Offset(0, 10), timeStamp: const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await g2.up(timeStamp: const Duration(milliseconds: 300));
      await settle(tester);
      expect(rs.composer.open, isTrue);
    });
  }

  iosTest('a composer notify mid-pull does not spring the panel back; release past 70 still collapses', (tester) async {
    await openOn(tester, tsess);
    final r = tester.getRect(panel);
    final g = await tester.startGesture(r.topLeft + const Offset(3, 3));
    await g.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 16));
    await tester.pump(frame);
    await g.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 32));
    await tester.pump(frame);
    final top = tester.getRect(panel).top;
    tsess.composer.setSending(true); // any notify while the panel is open
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(panel).top, closeTo(top, 0.5));
    await g.up(timeStamp: const Duration(milliseconds: 32));
    await tester.pump();
    expect(tsess.composer.open, isFalse);
  });
}
