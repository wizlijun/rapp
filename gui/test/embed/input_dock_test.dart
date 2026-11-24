// The input dock (input-dock spec §4–§5): one floating block per session on every platform — the text area on top,
// 8, the 快捷区 at the bottom — standing on its anchor; the picture never moves. iOS's button stack stands above it.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart' show InputPoint, ResolvedProfile, defaultComposerAt;
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/input_dock.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/panel_place.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stage_buttons.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart' show keyboardLift;
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import 'voice_button_test.dart' show FakeVoice;

void main() {
  late Directory tmp;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  late RemoteSession app, tsess, tapp;
  var stage = const Size(1000, 700);

  MainState stateWith({FakeVoice? voice}) =>
      // The geometry below is the bare key bar; the 常用语条's 36 is pinned in key_bar_test.
      MainState(
          hub: HubClient(FakeTransport()),
          data: DataDir(tmp.path),
          prefs: UiPrefs(phraseStrip: false),
          port: port,
          termPort: term,
          voice: voice);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('input_dock_test');
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    stage = const Size(1000, 700);
    s = stateWith();
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

  const frame = Duration(milliseconds: 16);

  void dockTest(TargetPlatform p, String name, Future<void> Function(WidgetTester) body) =>
      testWidgets('${p.name}: $name', (tester) async {
        debugDefaultTargetPlatformOverride = p;
        try {
          tester.view.physicalSize = stage;
          tester.view.devicePixelRatio = 1;
          await body(tester);
        } finally {
          tester.view.reset();
          debugDefaultTargetPlatformOverride = null;
        }
      });

  void iosTest(String name, Future<void> Function(WidgetTester) body) => dockTest(TargetPlatform.iOS, name, body);

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

  final panel = find.byType(ComposerPanel);
  final toggle = find.byKey(const Key('composer-open'));
  final bar = find.byType(KeyBar);
  final handle = find.byKey(const Key('quick-handle'));
  final stackToggle = find.byKey(const Key('quick-toggle-stack'));
  final boxToggle = find.byKey(const Key('quick-toggle'));
  final barKeys = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('bar-'));

  // Up off the stage's bottom.
  double bottomOf(WidgetTester tester, Finder f) => stage.height - tester.getRect(f).bottom;
  double topOf(WidgetTester tester, Finder f) => stage.height - tester.getRect(f).top;
  double barH(RemoteSession rs) => keyBarHeightOf(s, rs);
  // The default anchor's height off the stage's bottom on this platform.
  double anchor() => defaultTargetPlatform == TargetPlatform.iOS
      ? defaultComposerAt.dy
      : desktopComposerAt(controlHeightFor(defaultTargetPlatform)).dy;
  Rect block(RemoteSession rs) => panelPlaceOf(rs).value!;
  double fade(WidgetTester tester) => tester.widget<Opacity>(find.byKey(const Key('dock-panel-fade'))).opacity;
  // To a thousandth of a pixel: the block's top is its bottom less a growing height, and the sum back down to a
  // key carries float noise (~1e-13) that no screen can show.
  double milli(double v) => (v * 1000).roundToDouble() / 1000;
  List<Rect> keyRects(WidgetTester tester) => [
        for (final e in barKeys.evaluate())
          if (tester.getRect(find.byWidget(e.widget)) case final r)
            Rect.fromLTRB(milli(r.left), milli(r.top), milli(r.right), milli(r.bottom))
      ];

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(); // the block's place reaches the stack a frame later
  }

  Future<void> openOn(WidgetTester tester, RemoteSession rs) async {
    await tester.pumpWidget(layer(rs));
    rs.composer.open = true;
    await settle(tester);
    expect(panel, findsOneWidget);
  }

  test('restStackBottom, stackBottomOf and desktopComposerAt', () {
    expect(restStackBottom(0), stageButtonsUp);
    expect(restStackBottom(300), 300 + stageButtonsEdge);
    const st = Size(1000, 700);
    expect(stackBottomOf(stage: st, block: null, keyboard: 0, stackHeight: 56), stageButtonsUp);
    expect(stackBottomOf(stage: st, block: const Rect.fromLTWH(140, 600, 720, 0), keyboard: 0, stackHeight: 56),
        stageButtonsUp);
    expect(stackBottomOf(stage: st, block: const Rect.fromLTWH(140, 500, 720, 192), keyboard: 0, stackHeight: 56),
        208);
    // Never off the stage's top.
    expect(stackBottomOf(stage: st, block: const Rect.fromLTWH(140, 10, 720, 600), keyboard: 0, stackHeight: 56),
        700 - 8 - 56);
    expect(desktopComposerAt(40), const InputPoint(0.5, 60, fromBottom: true));
    expect(closedStackHeight(buttons: 0, upright: false), 0);
    expect(closedStackHeight(buttons: 3, upright: false), 3 * stageButtonSize + 2 * 12);
    expect(closedStackHeight(buttons: 3, upright: true), stageButtonSize);
  });

  for (final p in [TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.linux]) {
    dockTest(p, 'terminal: quick area at panelWidth, bottom at the default anchor, no handle', (tester) async {
      await tester.pumpWidget(layer(tsess));
      await tester.pump();
      expect(bar, findsOneWidget);
      expect(tester.getSize(bar).width, panelWidth(stage.width));
      expect(tester.getCenter(bar).dx, stage.width / 2);
      expect(bottomOf(tester, bar), anchor());
      expect(handle, findsNothing);
      expect(panel, findsNothing);
    });

    dockTest(p, 'Safari, both folded: no block, the stack toggle brings the KeyBar back', (tester) async {
      await tester.pumpWidget(layer(app));
      await tester.pump();
      expect(bar, findsNothing);
      expect(handle, findsNothing);
      await tester.tap(stackToggle);
      await settle(tester);
      expect(s.prefs.quickHiddenApp, isFalse);
      expect(bar, findsOneWidget);
      expect(bottomOf(tester, bar), anchor());
    });

    dockTest(p, 'opening the text area leaves every bar-* key rect unchanged; the text area ends 8 above the bar',
        (tester) async {
      await tester.pumpWidget(layer(tsess));
      await tester.pump();
      final before = keyRects(tester);
      expect(before, isNotEmpty);
      tsess.composer.open = true;
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        await tester.pump(frame);
        expect(keyRects(tester), before, reason: 'frame $i');
      }
      await settle(tester);
      expect(keyRects(tester), before);
      expect(tester.getRect(panel).bottom, tester.getRect(bar).top - 8);
      expect(tester.getSize(panel).width, panelWidth(stage.width));
    });

    dockTest(p, 'showing the quick area keeps the block bottom; an open text area rises by keyBarHeightOf + 8',
        (tester) async {
      await openOn(tester, app);
      expect(bar, findsNothing);
      final bottom = block(app).bottom;
      final text = tester.getRect(panel).bottom;
      expect(stage.height - text, anchor());
      await tester.tap(boxToggle);
      await settle(tester);
      expect(bar, findsOneWidget);
      expect(block(app).bottom, bottom);
      expect(bottomOf(tester, bar), anchor());
      expect(tester.getRect(panel).bottom, text - barH(app) - 8);
    });

    dockTest(p, 'the box toggle folds the quick area; no handle comes; the open text area falls to the anchor',
        (tester) async {
      await openOn(tester, tsess);
      expect(bottomOf(tester, panel), anchor() + barH(tsess) + 8);
      await tester.tap(boxToggle);
      await settle(tester);
      expect(s.prefs.quickHiddenTerm, isTrue);
      expect(bar, findsNothing);
      expect(handle, findsNothing);
      expect(bottomOf(tester, panel), anchor());
    });

    dockTest(p, 'close then open within 200ms: one ComposerPanel, same State, draft intact', (tester) async {
      await openOn(tester, app);
      await tester.enterText(find.byKey(const Key('composer-field')), 'hello');
      await tester.pump();
      final before = tester.state(panel);
      final at = bottomOf(tester, panel);
      app.composer.collapse();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(panel, findsOneWidget);
      app.composer.open = true;
      await settle(tester);
      expect(panel, findsOneWidget);
      expect(identical(tester.state(panel), before), isTrue);
      expect(tester.widget<TextField>(find.byKey(const Key('composer-field'))).controller!.text, 'hello');
      expect(bottomOf(tester, panel), at);
      expect(fade(tester), 1);
    });

    dockTest(p, 'disableAnimations: text and quick land in one frame', (tester) async {
      await tester.pumpWidget(layer(tsess, reduced: true));
      tsess.composer.open = true;
      await tester.pump();
      expect(panel, findsOneWidget);
      expect(bottomOf(tester, panel), anchor() + barH(tsess) + 8);
      s.setQuickHidden(term: true, hidden: true);
      await tester.pump();
      expect(bar, findsNothing);
      expect(bottomOf(tester, panel), anchor());
      s.setQuickHidden(term: true, hidden: false);
      await tester.pump();
      expect(bottomOf(tester, bar), anchor());
      expect(bottomOf(tester, panel), anchor() + barH(tsess) + 8);
      tsess.composer.collapse();
      await tester.pump();
      expect(panel, findsNothing);
      expect(bottomOf(tester, bar), anchor());
    });

    dockTest(p, 'session switch terminal → Safari: the stack toggle only, the terminal KeyBar is gone; a picture key no longer '
        'changes quick_hidden_term', (tester) async {
      s.setQuickAutoHide(true);
      await tester.pumpWidget(layer(tapp));
      await tester.pump();
      expect(bar, findsOneWidget);
      // Typed into the terminal app's picture, a key folds its 快捷区: the check below can fail.
      s.pictureFocused = tapp.sid;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(s.prefs.quickHiddenTerm, isTrue);
      s.setQuickHidden(term: true, hidden: false);
      await tester.pumpWidget(layer(app));
      await settle(tester);
      expect(bar, findsNothing);
      expect(stackToggle, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(s.prefs.quickHiddenTerm, isFalse);
      s.pictureFocused = app.sid;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      expect(s.prefs.quickHiddenTerm, isFalse);
    });
  }

  iosTest('keyboard 300: the block bottom 308; both folded, nothing on the block and the stack at '
      'restStackBottom(300)', (tester) async {
    keyboard(tester, 300);
    await tester.pumpWidget(layer(tsess));
    await settle(tester);
    expect(bottomOf(tester, bar), 308);
    expect(stage.height - block(tsess).bottom, 308);
    await tester.pumpWidget(layer(app));
    await settle(tester);
    expect(bar, findsNothing);
    expect(handle, findsNothing);
    expect(bottomOf(tester, toggle), restStackBottom(300));
  });

  iosTest('keyboard rising 0→300 over frames: the block bottom is max(anchor, keyboard + 8) every frame',
      (tester) async {
    await tester.pumpWidget(layer(tsess));
    tsess.composer.open = true;
    await tester.pump();
    for (var i = 1; i <= 25; i++) {
      final k = 300.0 * math.min(1.0, i / 15);
      keyboard(tester, k);
      await tester.pump(frame);
      expect(bottomOf(tester, bar), closeTo(math.max(anchor(), k + 8), 0.01), reason: 'frame $i');
    }
    await settle(tester);
    expect(bottomOf(tester, bar), 308);
    expect(bottomOf(tester, panel), 308 + barH(tsess) + 8);
    expect(bottomOf(tester, toggle), topOf(tester, find.byKey(const Key('composer-grip'))) + 8);
  });

  iosTest('the stack stands 8 above the block top; both folded at restStackBottom', (tester) async {
    await tester.pumpWidget(layer(tsess));
    await settle(tester);
    expect(bottomOf(tester, toggle), stage.height - block(tsess).top + 8);
    expect(block(tsess).top, lessThan(tester.getRect(bar).top), reason: 'the grip tops the quick area');
    tsess.composer.open = true;
    await settle(tester);
    expect(bottomOf(tester, toggle), stage.height - block(tsess).top + 8);
    expect(block(tsess).top, lessThan(tester.getRect(panel).top));
    await tester.pumpWidget(layer(app));
    await settle(tester);
    expect(handle, findsNothing);
    expect(bottomOf(tester, toggle), restStackBottom(0));
  });

  iosTest('a voice hold changes neither quick_hidden_* nor the stack bottom', (tester) async {
    s.dispose();
    s = stateWith(voice: FakeVoice());
    for (final rs in [tsess, app]) {
      await tester.pumpWidget(layer(rs));
      await settle(tester);
      final voice = find.byKey(const Key('voice-hold'));
      final at = bottomOf(tester, voice);
      final quick = (s.prefs.quickHiddenTerm, s.prefs.quickHiddenApp);
      final bars = bar.evaluate().length;
      final g = await tester.startGesture(tester.getCenter(voice));
      for (var i = 0; i < 30; i++) {
        await tester.pump(frame);
        expect(bottomOf(tester, voice), at, reason: '${rs.appName} frame $i');
      }
      expect((s.prefs.quickHiddenTerm, s.prefs.quickHiddenApp), quick);
      expect(bar.evaluate().length, bars);
      await g.up();
      await settle(tester);
      expect((s.prefs.quickHiddenTerm, s.prefs.quickHiddenApp), quick);
      expect(bar.evaluate().length, bars);
      expect(bottomOf(tester, voice), at);
      await tester.pump(const Duration(seconds: 2));
    }
  });

  iosTest('terminal block at its lowest: pull 80 folds the text area only, the KeyBar stays; pull 40 springs back',
      (tester) async {
    s.placeComposer(tsess, const InputPoint(0.5, 8, fromBottom: true));
    await openOn(tester, tsess);
    final quick = tester.getRect(bar);
    final grip = find.byKey(const Key('composer-grip'));
    final from = tester.getCenter(grip);
    var g = await tester.startGesture(from);
    await g.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 16));
    await tester.pump(frame);
    await g.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 32));
    await tester.pump(frame);
    expect(tsess.composer.open, isTrue);
    await g.up(timeStamp: const Duration(milliseconds: 32));
    await tester.pump();
    expect(tsess.composer.open, isFalse);
    await settle(tester);
    expect(panel, findsNothing);
    expect(bar, findsOneWidget);
    expect(tester.getRect(bar), quick);
    expect(s.prefs.quickHiddenTerm, isFalse);

    tsess.composer.open = true;
    await settle(tester);
    final top0 = tester.getRect(panel).top;
    g = await tester.startGesture(tester.getCenter(grip));
    for (var i = 1; i <= 2; i++) {
      await g.moveBy(const Offset(0, 20), timeStamp: Duration(milliseconds: 300 * i));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(tester.getRect(panel).top, closeTo(top0 + 40, 0.5));
    await g.up(timeStamp: const Duration(milliseconds: 600));
    await settle(tester);
    expect(tsess.composer.open, isTrue);
    expect(tester.getRect(panel).top, closeTo(top0, 0.5));
    expect(tester.getRect(bar), quick);
  });

  iosTest('close then open in its last 100 ms: the text area fades back in from where it was, no snap to opaque',
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
    expect(bottomOf(tester, panel), anchor() + barH(tsess) + 8);
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

  iosTest('swipe up 40 on bar-up sends PgUp; the block rect is unchanged', (tester) async {
    await tester.pumpWidget(layer(tsess));
    await settle(tester);
    final before = block(tsess);
    term.calls.clear();
    final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('bar-up'))));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, -10));
      await tester.pump(frame);
      expect(block(tsess), before, reason: 'move $i');
    }
    await g.up();
    await settle(tester);
    expect([for (final c in term.calls) if (c.$1 == 'keys') c.$2['keys']], [
      ['PageUp'],
    ]);
    expect(block(tsess), before);
  });

  for (final which in ['terminal', 'Safari']) {
    iosTest('$which: reopened during a pull-close, the text area springs back; a 10pt drag does not collapse',
        (tester) async {
      final rs = which == 'terminal' ? tsess : app;
      await openOn(tester, rs);
      final top0 = tester.getRect(panel).top;
      final from = tester.getCenter(find.byKey(const Key('composer-grip')));
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

  iosTest('a composer notify mid-pull does not spring the block back; release past 70 still collapses', (tester) async {
    await openOn(tester, tsess);
    final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('composer-grip'))));
    await g.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 16));
    await tester.pump(frame);
    await g.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 32));
    await tester.pump(frame);
    final top = tester.getRect(panel).top;
    tsess.composer.setSending(true); // any notify while the text area is open
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(panel).top, closeTo(top, 0.5));
    await g.up(timeStamp: const Duration(milliseconds: 32));
    await tester.pump();
    expect(tsess.composer.open, isFalse);
  });

  bool lit(WidgetTester tester, Finder f) => tester.widget<RappButton>(f).active;

  iosTest('text folded — the toggle stands in the stack, 56 square, lit while the 快捷区 shows', (tester) async {
    await tester.pumpWidget(layer(tsess));
    await settle(tester);
    expect(boxToggle, findsNothing);
    expect(tester.getSize(stackToggle), const Size.square(stageButtonSize));
    expect(tester.getRect(stackToggle).bottom, tester.getRect(toggle).top - 12);
    expect(lit(tester, stackToggle), isTrue);
    await tester.tap(stackToggle);
    await settle(tester);
    expect(s.prefs.quickHiddenTerm, isTrue);
    expect(bar, findsNothing);
    expect(lit(tester, stackToggle), isFalse);
    await tester.tap(stackToggle);
    await settle(tester);
    expect(bar, findsOneWidget);
  });

  for (final p in [TargetPlatform.macOS, TargetPlatform.linux]) {
    dockTest(p, 'text folded — the toggle stands left of 输入 in the corner row, 8 apart',
        (tester) async {
      await tester.pumpWidget(layer(app));
      await settle(tester);
      expect(boxToggle, findsNothing);
      final q = tester.getRect(stackToggle), o = tester.getRect(toggle);
      expect(o.left - q.right, 8);
      expect(q.size, o.size);
      expect(q.center.dy, o.center.dy);
      expect(lit(tester, stackToggle), isFalse, reason: 'an app hides its 快捷区 by default');
      await tester.tap(stackToggle);
      await settle(tester);
      expect(s.prefs.quickHiddenApp, isFalse);
      expect(bar, findsOneWidget);
      expect(lit(tester, stackToggle), isTrue);
    });
  }

  for (final p in [TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.linux]) {
    dockTest(p, 'text open — no stack toggle, the box one only', (tester) async {
      await openOn(tester, tsess);
      expect(stackToggle, findsNothing);
      expect(boxToggle, findsOneWidget);
    });

    dockTest(p, 'no toggle where the composer is not allowed', (tester) async {
      app.setProfile(const ResolvedProfile(name: 'X', composer: false));
      await tester.pumpWidget(layer(app));
      await settle(tester);
      expect(stackToggle, findsNothing);
      expect(boxToggle, findsNothing);
    });
  }
}
