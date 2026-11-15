import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_layout.dart';
import 'package:rapp/term/term_model.dart';
import 'package:rapp/term/term_painter.dart';
import 'package:rapp/term/term_palette.dart';
import 'package:rapp/term/term_session_port.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/disconnected_stage.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

TermScreen scr(List<String> rows, {int rev = 1, int? hist, int? limit, int cx = 0, int cy = 0}) => TermScreen(
      pane: '%3',
      rev: rev,
      cols: 40,
      rows: rows.length,
      cx: cx,
      cy: cy,
      cursor: true,
      alt: false,
      full: true,
      more: false,
      lines: [for (var i = 0; i < rows.length; i++) (i, rows[i])],
      hist: hist,
      limit: limit,
      wrapped: const {},
    );

RemoteWindow win(int id) => RemoteWindow(
      id: id,
      parent: 0,
      kind: WindowKind.normal,
      title: 'p$id',
      rect: Rect.zero,
      titleBar: 0,
      resizable: false,
      focused: true,
      texture: null,
      visible: Rect.zero,
    );

TermPane tp(int n, String command, {bool active = false, bool dead = false}) => TermPane(
      id: '%$n',
      win: '@$n',
      window: command,
      title: command,
      command: command,
      cols: 80,
      rows: 24,
      dead: dead,
      active: active,
    );

final _macLinux = TargetPlatformVariant.only(TargetPlatform.macOS)..values.add(TargetPlatform.linux);

void main() {
  group('the stage on its own', () {
    late Directory tmp;
    late MainState state;
    late RemoteSession session;
    late FakeTermSessionPort port;
    late TermModel model;
    final metrics = TermMetrics.measure(termTextStyle(themeDataFor(RappTheme.matrix).extension<RappTokens>()!));
    final ch = metrics.cellH;

    // The window's shortcuts as main_window.dart binds them on Linux (its builder reads Platform.isMacOS, so it
    // cannot be made to bind Linux's here): each counts when it fires.
    final fired = <String, int>{};
    void hit(String k) => fired[k] = (fired[k] ?? 0) + 1;
    Widget windowKeys(Widget child) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.f11): () => hit('fullscreen'),
            const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): () => hit('esc'),
            const SingleActivator(LogicalKeyboardKey.enter, control: true, includeRepeats: false): () =>
                hit('composer'),
            const SingleActivator(LogicalKeyboardKey.bracketLeft, control: true): () => hit('prev'),
            const SingleActivator(LogicalKeyboardKey.bracketRight, control: true): () => hit('next'),
            const SingleActivator(LogicalKeyboardKey.keyO, control: true, includeRepeats: false): () =>
                hit('overview'),
          },
          child: Focus(autofocus: true, child: child),
        );

    setUp(() {
      fired.clear();
      tmp = Directory.systemTemp.createTempSync('term_stage_keys_test');
      model = TermModel()..expect('%3');
      port = FakeTermSessionPort()..seed(1, model: model, panes: [tp(3, 'claude', active: true)]);
      state = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), termPort: port);
      session = RemoteSession(1, 'term')..apply(WindowsEvent(1, [win(3)]));
    });
    tearDown(() {
      state.dispose();
      port.dispose();
      tmp.deleteSync(recursive: true);
    });

    Future<void> show(WidgetTester t) async {
      await t.pumpWidget(wrap(windowKeys(SizedBox(
        width: 800,
        height: 480,
        child: TermStage(state: state, session: session, port: port),
      ))));
    }

    /// A click on the grid gives the stage the keyboard.
    Future<void> focusStage(WidgetTester t) async {
      await t.tap(find.byKey(const Key('term-grid')));
      await t.pump();
      expect(Focus.of(t.element(find.byKey(const Key('term-grid')))).hasFocus, isTrue);
      port.calls.clear();
    }

    List<Object?> sent() => [
          for (final c in port.calls)
            if (c.$1 == 'keys') c.$2['keys'] else if (c.$1 == 'type') 'type:${c.$2['text']}',
        ];

    Future<void> chord(WidgetTester t, List<LogicalKeyboardKey> mods, LogicalKeyboardKey key) async {
      for (final m in mods) {
        await t.sendKeyDownEvent(m);
      }
      await t.sendKeyEvent(key);
      for (final m in mods.reversed) {
        await t.sendKeyUpEvent(m);
      }
      await t.pump();
    }

    void clipboard(WidgetTester t, String text) {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': text};
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    }

    Future<void> pasteKey(WidgetTester t) => defaultTargetPlatform == TargetPlatform.macOS
        ? chord(t, [LogicalKeyboardKey.metaLeft], LogicalKeyboardKey.keyV)
        : chord(t, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.keyV);

    TermPainter painter(WidgetTester t) =>
        t.widget<CustomPaint>(find.byKey(const Key('term-grid'))).painter! as TermPainter;

    testWidgets('Ctrl+R, Ctrl+L, Shift+Tab and Up go to the terminal (G2 acceptance)', (t) async {
      model.apply(scr(['\$ ']));
      await show(t);
      await focusStage(t);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyR);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyL);
      await chord(t, [LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.tab);
      await chord(t, [], LogicalKeyboardKey.arrowUp);
      await chord(t, [], LogicalKeyboardKey.keyX);
      expect(sent(), [
        ['Ctrl-r'],
        ['Ctrl-l'],
        ['Shift-Tab'],
        ['Up'],
        'type:x',
      ]);
      expect(fired, isEmpty);
    }, variant: _macLinux);

    testWidgets('on Linux the window keys go to the terminal and the window does nothing (Review Focus 1)',
        (t) async {
      model.apply(scr(['\$ ']));
      await show(t);
      await focusStage(t);
      await chord(t, [], LogicalKeyboardKey.escape);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.bracketLeft);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.bracketRight);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyO);
      await chord(t, [], LogicalKeyboardKey.f11);
      expect(sent(), [
        ['Esc'],
        ['Ctrl-['],
        ['Ctrl-]'],
        ['Ctrl-o'],
        ['F11'],
      ]);
      expect(fired, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Ctrl+Enter is not sent: it goes on to the window', (t) async {
      model.apply(scr(['\$ ']));
      await show(t);
      await focusStage(t);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.enter);
      expect(sent(), isEmpty);
      expect(fired, {'composer': 1});
    }, variant: _macLinux);

    testWidgets('with a selection Esc only clears it', (t) async {
      model.apply(scr(['abcdef']));
      await show(t);
      await focusStage(t);
      final g = await t.startGesture(t.getTopLeft(find.byKey(const Key('term-grid'))) + const Offset(2, 2),
          kind: PointerDeviceKind.mouse);
      await g.moveBy(Offset(metrics.cellW * 3, 0));
      await g.up();
      await t.pump();
      expect(find.byKey(const Key('term-copy')), findsOneWidget);
      await chord(t, [], LogicalKeyboardKey.escape);
      expect(find.byKey(const Key('term-copy')), findsNothing);
      expect(sent(), isEmpty);
      await chord(t, [], LogicalKeyboardKey.escape);
      expect(sent(), [
        ['Esc'],
      ]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('an exited pane gets no keys, text or pastes; the window keys work again (Review Focus 4)',
        (t) async {
      port.paneLists[1] = [tp(3, 'claude', active: true, dead: true)];
      clipboard(t, 'one line');
      model.apply(scr(['\$ ']));
      await show(t);
      await focusStage(t);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyR);
      await chord(t, [], LogicalKeyboardKey.keyX);
      await pasteKey(t);
      await t.pump();
      // Nothing for the terminal to take, so the window's own keys are the window's again.
      await chord(t, [], LogicalKeyboardKey.escape);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.bracketLeft);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.bracketRight);
      await chord(t, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyO);
      await chord(t, [], LogicalKeyboardKey.f11);
      expect(port.calls.where((c) => {'keys', 'type', 'paste'}.contains(c.$1)), isEmpty);
      expect(fired, {'esc': 1, 'prev': 1, 'next': 1, 'overview': 1, 'fullscreen': 1});
      await t.pump(const Duration(milliseconds: 400));
      expect(painter(t).waiting, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('a letter typed while reading history goes back to the latest', (t) async {
      final rows = [for (var i = 0; i < 10; i++) 'row $i'];
      model.apply(scr(rows, hist: 5, limit: 2000));
      model.applyHistory(const TermHistory(pane: '%3', before: 0, lines: ['h-5', 'h-4', 'h-3', 'h-2', 'h-1'], hist: 5));
      await show(t);
      await focusStage(t);
      final p = TestPointer(1, PointerDeviceKind.mouse);
      await t.sendEventToBinding(p.hover(t.getCenter(find.byKey(const Key('term-grid')))));
      await t.sendEventToBinding(p.scroll(Offset(0, -3 * ch)));
      await t.pump();
      expect(model.offset, greaterThan(0));
      await chord(t, [], LogicalKeyboardKey.keyQ);
      expect(sent(), ['type:q']);
      expect(model.offset, 0);
      expect(find.byKey(const Key('term-latest')), findsNothing);
    }, variant: _macLinux);

    testWidgets('pasting one line sends it as a paste and leaves the writing panel shut', (t) async {
      clipboard(t, 'git status');
      model.apply(scr(['\$ ']));
      await show(t);
      await focusStage(t);
      await pasteKey(t);
      await t.pump();
      expect(port.calls.where((c) => c.$1 == 'paste').map((c) => c.$2).toList(), [
        {'sid': 1, 'data': 'git status', 'enter': false},
      ]);
      expect(session.composer.open, isFalse);
      expect(session.composer.pasteTick, 0);
      expect(sent(), isEmpty);
    }, variant: _macLinux);

    testWidgets('a one-line paste is input too: back to the latest, and the ellipsis wait (H3, K6)', (t) async {
      clipboard(t, 'git status');
      final rows = [for (var i = 0; i < 10; i++) 'row $i'];
      model.apply(scr(rows, hist: 5, limit: 2000));
      model.applyHistory(const TermHistory(pane: '%3', before: 0, lines: ['h-5', 'h-4', 'h-3', 'h-2', 'h-1'], hist: 5));
      await show(t);
      await focusStage(t);
      final p = TestPointer(1, PointerDeviceKind.mouse);
      await t.sendEventToBinding(p.hover(t.getCenter(find.byKey(const Key('term-grid')))));
      await t.sendEventToBinding(p.scroll(Offset(0, -3 * ch)));
      await t.pump();
      expect(model.offset, greaterThan(0));
      await pasteKey(t);
      await t.pump();
      expect(port.calls.where((c) => c.$1 == 'paste'), hasLength(1));
      expect(model.offset, 0);
      expect(painter(t).waiting, isFalse);
      await t.pump(const Duration(milliseconds: 350));
      expect(painter(t).waiting, isTrue);
    }, variant: _macLinux);

    testWidgets('pasting three lines opens the writing panel for its own paste instead', (t) async {
      clipboard(t, 'a\nb\nc');
      model.apply(scr(['\$ ']));
      await show(t);
      await focusStage(t);
      final focusTick = session.composer.focusTick;
      await pasteKey(t);
      await t.pump();
      expect(port.calls.where((c) => c.$1 == 'paste'), isEmpty);
      expect(session.composer.open, isTrue);
      expect(session.composer.pasteTick, 1);
      expect(session.composer.focusTick, greaterThan(focusTick));
      expect(sent(), isEmpty);
    }, variant: _macLinux);

    testWidgets('with the writing panel off, three lines go straight in as one paste (K4)', (t) async {
      clipboard(t, 'a\nb\nc');
      session.setProfile(const ResolvedProfile(name: 'term', composer: false));
      final rows = [for (var i = 0; i < 10; i++) 'row $i'];
      model.apply(scr(rows, hist: 5, limit: 2000));
      model.applyHistory(const TermHistory(pane: '%3', before: 0, lines: ['h-5', 'h-4', 'h-3', 'h-2', 'h-1'], hist: 5));
      await show(t);
      await focusStage(t);
      final p = TestPointer(1, PointerDeviceKind.mouse);
      await t.sendEventToBinding(p.hover(t.getCenter(find.byKey(const Key('term-grid')))));
      await t.sendEventToBinding(p.scroll(Offset(0, -3 * ch)));
      await t.pump();
      expect(model.offset, greaterThan(0));
      await pasteKey(t);
      await t.pump();
      expect(port.calls.where((c) => c.$1 == 'paste').map((c) => c.$2).toList(), [
        {'sid': 1, 'data': 'a\nb\nc', 'enter': false},
      ]);
      expect(session.composer.open, isFalse);
      expect(session.composer.pasteTick, 0);
      // Input, as a one-line paste is: back to the latest, and the ellipsis wait (H3, K6).
      expect(model.offset, 0);
      await t.pump(const Duration(milliseconds: 350));
      expect(painter(t).waiting, isTrue);
    }, variant: _macLinux);

    testWidgets('a paste that does not go in shows why on the stage', (t) async {
      clipboard(t, 'x');
      port.pasteReply = pasteTooLong;
      model.apply(scr(['\$ ']));
      await show(t);
      await focusStage(t);
      await pasteKey(t);
      await t.pump();
      expect(find.text(pasteTooLong), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('no new screen 0.3 s after a key: an ellipsis after the cursor until one comes (K6)', (t) async {
      model.apply(scr(['\$ ', ''], cx: 2));
      await show(t);
      await focusStage(t);
      expect(painter(t).waiting, isFalse);

      await chord(t, [], LogicalKeyboardKey.keyA);
      await t.pump(const Duration(milliseconds: 250));
      expect(painter(t).waiting, isFalse);
      await t.pump(const Duration(milliseconds: 100));
      expect(painter(t).waiting, isTrue);

      model.apply(scr(['\$ a', ''], rev: 2, cx: 3));
      await t.pump();
      expect(painter(t).waiting, isFalse);

      // A screen within 0.3 s: no ellipsis at all.
      await chord(t, [], LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 100));
      model.apply(scr(['\$ a', '\$ '], rev: 3, cx: 2, cy: 1));
      await t.pump(const Duration(milliseconds: 400));
      expect(painter(t).waiting, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('keys every 0.2 s with no screen: the ellipsis still shows 0.3 s after the first (K6)', (t) async {
      model.apply(scr(['\$ ', ''], cx: 2));
      await show(t);
      await focusStage(t);
      await chord(t, [], LogicalKeyboardKey.keyA);
      await t.pump(const Duration(milliseconds: 200));
      await chord(t, [], LogicalKeyboardKey.keyB);
      await t.pump(const Duration(milliseconds: 150));
      expect(painter(t).waiting, isTrue);
      await t.pump(const Duration(milliseconds: 50));
      await chord(t, [], LogicalKeyboardKey.keyC);
      expect(painter(t).waiting, isTrue);
      expect(sent(), ['type:a', 'type:b', 'type:c']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('the painter draws the ellipsis one cell after the cursor', (t) async {
      model.apply(scr(['\$ ', ''], cx: 2));
      final cache = TermRowCache();
      addTearDown(cache.dispose);
      TermPainter p(bool waiting) => TermPainter(
            model: model,
            metrics: metrics,
            palette: termPaletteFor(RappTheme.matrix, themeDataFor(RappTheme.matrix).extension<RappTokens>()!),
            cache: cache,
            version: waiting ? 1 : 0,
            focused: true,
            waiting: waiting,
          );
      expect(p(true).shouldRepaint(p(false)), isTrue);
      // Paints without throwing, with and without.
      for (final w in [false, true]) {
        final rec = PictureRecorder();
        p(w).paint(Canvas(rec), const Size(400, 100));
        rec.endRecording().dispose();
      }
    });
  });

  group('the stage in the window', () {
    late FakeTransport tr;
    late HubClient hub;
    late Directory tmp;
    late FakeSessionPort native;
    late FakeTermSessionPort term;
    late MainState s;
    var nextSid = 1;

    Future<void> flush() => Future<void>.delayed(Duration.zero);

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('term_stage_keys_test');
      tr = FakeTransport();
      hub = HubClient(tr);
      tr.emit({
        'event': 'hosts',
        'hosts': [
          {'id': '111', 'name': 'mini'},
        ],
      });
      await flush();
      nextSid = 1;
      tr.onSend = (m) {
        if (m['cmd'] == 'open') {
          tr.emit({
            'event': 'opened', 'sid': nextSid++, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            'port': 5001, 'token': 'tk', 'req': m['req'],
          });
        }
      };
      native = FakeSessionPort();
      term = FakeTermSessionPort();
      s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: native, termPort: term);
    });

    tearDown(() {
      s.dispose();
      term.dispose();
      tmp.deleteSync(recursive: true);
    });

    Widget window() => SizedBox(
          width: 1200,
          height: 700,
          child: Column(children: [
            TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
            Expanded(child: Stage(state: s)),
          ]),
        );

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      await tester.pump();
    }

    WindowsEvent windowsOf(Object sid, List<TermPane> panes) => WindowsEvent(sid, [
          for (final p in panes) win(p.number),
        ]);

    Future<void> openTerm(WidgetTester tester, List<TermPane> panes) async {
      term.paneLists[1] = panes;
      await tester.runAsync(() async {
        s.openOrSwitch('111', 'term:tmux:work', 'work');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
      term.play(const ReadyEvent(1, 'claude'));
      term.play(windowsOf(1, panes));
      term.play(const TrafficEvent(1, 0, 1));
      await settle(tester);
    }

    bool stageFocused(WidgetTester t) => Focus.of(t.element(find.byKey(const Key('term-grid')))).hasFocus;

    testWidgets('an opened terminal takes the keyboard; focusPicture gives it back', (t) async {
      await t.pumpWidget(wrap(window()));
      await openTerm(t, [tp(3, 'claude', active: true)]);
      expect(find.byType(TermStage), findsOneWidget);
      expect(stageFocused(t), isTrue);

      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(stageFocused(t), isFalse);
      final tick = s.termFocusTick;
      s.focusPicture(1);
      expect(s.termFocusTick, tick + 1);
      await t.pump();
      await t.pump();
      expect(stageFocused(t), isTrue);
      // A terminal's keys are not the runner's: the native port is not told.
      expect(native.calls.where((c) => c.$1 == 'picture_focus'), isEmpty);
    });

    testWidgets('keys typed after the session disconnected are not sent or kept (Review Focus 4)', (t) async {
      await t.pumpWidget(wrap(window()));
      await openTerm(t, [tp(3, 'claude', active: true)]);
      expect(stageFocused(t), isTrue);
      term.play(const DisconnectedEvent(1, 'session ended'));
      await settle(t);
      expect(find.byType(DisconnectedStage), findsOneWidget);
      term.calls.clear();
      await t.sendKeyEvent(LogicalKeyboardKey.keyX);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      expect(term.calls.where((c) => c.$1 == 'keys' || c.$1 == 'type'), isEmpty);
    });
  });
}
