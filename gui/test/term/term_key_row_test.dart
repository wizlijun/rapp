// The terminal key row (G2 task 7): six big keys so a terminal can be interrupted and driven without a keyboard.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_key_row.dart';
import 'package:rapp/embed/composer_panel.dart' show ComposerPanel, pictureLift;
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_key_row.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import '../ui/helpers.dart';
import 'term_main_test.dart' show tp, windowsOf;

const app = 'term:pty:work';

const left = ['Ctrl', 'Esc', 'Ctrl-C', 'Tab'];
const right = ['Up', 'Down', 'Enter'];

void main() {
  late FakeTransport t;
  late HubClient hub;
  late Directory tmp;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  var nextSid = 1;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('term_key_row_test');
    // A device id: prefs are written to devices/<id>/gui.json.
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"123456789"}');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    nextSid = 1;
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({
          'event': 'opened', 'sid': nextSid++, 'id': m['id'], 'app': m['app'], 'path': 'lan',
          'port': 5001, 'token': 'tk', 'req': m['req'],
        });
      }
    };
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
  });

  tearDown(() {
    s.dispose();
    term.dispose();
    tmp.deleteSync(recursive: true);
  });

  Widget window(double width) => SizedBox(
        width: width,
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

  Future<void> openTerm(WidgetTester tester, {double width = 1200}) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(window(width), disableAnimations: true));
    final panes = [tp(3, 'claude', title: 'build-box', active: true), tp(4, '', title: 'sh')];
    term.paneLists[1] = panes;
    await tester.runAsync(() async {
      s.openOrSwitch('111', app, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    term.play(const ReadyEvent(1, 'work'));
    term.play(windowsOf(1, panes));
    term.play(const TrafficEvent(1, 0, 1));
    await settle(tester);
    expect(find.byType(TermStage), findsOneWidget);
  }

  List<Map<String, Object?>> callsOf(String m) => term.calls.where((c) => c.$1 == m).map((c) => c.$2).toList();
  List<Object?> keys() => [for (final c in callsOf('keys')) c['keys']];
  Finder key(String name) => find.byKey(Key('keyrow-$name'));
  Rect rectOf(WidgetTester tester, Finder f) => tester.getRect(f);
  Rect group(WidgetTester tester, List<String> names) =>
      names.map((n) => tester.getRect(key(n))).reduce((a, b) => a.expandToInclude(b));
  String guiJson() => File('${tmp.path}/devices/123456789/gui.json').readAsStringSync();
  double stageTop(WidgetTester tester) => tester.getTopLeft(find.byType(TermStage)).dy;
  final fieldFinder = find.byKey(const Key('composer-field'));
  bool fieldFocused(WidgetTester tester) => tester.widget<TextField>(fieldFinder).focusNode!.hasFocus;
  bool stageFocused(WidgetTester tester) => Focus.of(tester.element(find.byKey(const Key('term-grid')))).hasFocus;

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('traffic')));
    await tester.pumpAndSettle();
  }

  Future<void> toggleFromMenu(WidgetTester tester) async {
    await openMenu(tester);
    await tester.tap(find.byKey(const Key('term-key-row')));
    await tester.pumpAndSettle();
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('composer-panel')), findsOneWidget);
  }

  /// Lets a view that waits for the stage to stop changing go out.
  Future<void> pastViewPause(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('off by default: no key row on a terminal', (tester) async {
    expect(UiPrefs().termKeyRow, isFalse);
    await openTerm(tester);
    for (final n in [...left, ...right]) {
      expect(key(n), findsNothing, reason: n);
    }
  });

  testWidgets('the traffic menu has 本机 · 按键排: on shows six keys and saves term_key_row; ticked; off again',
      (tester) async {
    await openTerm(tester);
    await openMenu(tester);
    expect(find.text('本机'), findsWidgets);
    expect(find.text('按键排'), findsOneWidget);
    final item = find.byKey(const Key('term-key-row'));
    expect(find.descendant(of: item, matching: find.byIcon(Icons.check)), findsNothing);
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(s.prefs.termKeyRow, isTrue);
    expect(guiJson(), contains('"term_key_row":true'));
    for (final (n, label) in [('Ctrl', '⌃'), ('Esc', 'Esc'), ('Ctrl-C', '⌃C'), ('Tab', 'Tab'), ('Up', '↑'), ('Down', '↓'), ('Enter', '⏎')]) {
      expect(key(n), findsOneWidget, reason: n);
      expect(find.descendant(of: key(n), matching: find.text(label)), findsOneWidget, reason: label);
      expect(tester.getSize(key(n)), const Size(52, 48), reason: n);
    }
    await openMenu(tester);
    expect(find.descendant(of: find.byKey(const Key('term-key-row')), matching: find.byIcon(Icons.check)),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('term-key-row')));
    await tester.pumpAndSettle();
    expect(s.prefs.termKeyRow, isFalse);
    expect(guiJson(), contains('"term_key_row":false'));
    expect(key('Esc'), findsNothing);
  });

  testWidgets('the traffic menu has 跟着我的窗口, ticked by default; a tap turns it off, saves term_fit and closes', (tester) async {
    await openTerm(tester);
    await openMenu(tester);
    final item = find.byKey(const Key('term-fit'));
    expect(find.text('跟着我的窗口'), findsOneWidget);
    expect(find.descendant(of: item, matching: find.byIcon(Icons.check)), findsOneWidget);
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(s.prefs.termFit, isFalse);
    expect(guiJson(), contains('"term_fit":false'));
    expect(find.byKey(const Key('term-fit')), findsNothing);
    await openMenu(tester);
    expect(find.descendant(of: find.byKey(const Key('term-fit')), matching: find.byIcon(Icons.check)), findsNothing);
  });

  testWidgets('each key sends its name; the stage keeps the keyboard', (tester) async {
    await openTerm(tester);
    await toggleFromMenu(tester);
    await tester.tap(find.byKey(const Key('term-grid')));
    await tester.pump();
    expect(stageFocused(tester), isTrue);
    term.calls.clear();
    await tester.tap(key('Esc'));
    await tester.pump();
    expect(keys(), [
      ['Esc'],
    ]);
    await tester.tap(key('Enter'));
    await tester.pump();
    for (final n in ['Ctrl-C', 'Tab', 'Up', 'Down']) {
      await tester.tap(key(n));
      await tester.pump();
    }
    expect(keys(), [
      ['Esc'],
      ['Enter'],
      ['Ctrl-C'],
      ['Tab'],
      ['Up'],
      ['Down'],
    ]);
    expect(stageFocused(tester), isTrue);
  });

  testWidgets('a key tapped while the panel is open leaves the caret in the panel', (tester) async {
    await openTerm(tester);
    await toggleFromMenu(tester);
    await openPanel(tester);
    await tester.enterText(fieldFinder, 'draft');
    expect(fieldFocused(tester), isTrue);
    term.calls.clear();
    await tester.tap(key('Ctrl-C'));
    await tester.pump();
    expect(keys(), [
      ['Ctrl-C'],
    ]);
    expect(fieldFocused(tester), isTrue);
    expect(tester.widget<TextField>(fieldFinder).controller!.text, 'draft');
  });

  for (final width in [1200, 1000]) {
    testWidgets('stage $width, panel closed: Esc ⌃C Tab bottom left, ↑ ↓ ⏎ bottom right, 「输入」 just left of them; '
        'the picture lifts $pictureLift', (tester) async {
      await openTerm(tester, width: width.toDouble());
      final top = stageTop(tester);
      final size = tester.getSize(find.byType(TermStage));
      await toggleFromMenu(tester);
      final stage = tester.getRect(find.byKey(const Key('stage')));
      final l = group(tester, left), r = group(tester, right);
      expect(l.left - stage.left, lessThan(24));
      expect(stage.right - r.right, lessThan(24));
      expect(stage.bottom - l.bottom, lessThan(24));
      expect(l.bottom, r.bottom);
      final input = rectOf(tester, find.byKey(const Key('composer-open')));
      expect(input.overlaps(r), isFalse);
      expect(input.right, lessThanOrEqualTo(r.left));
      expect(r.left - input.right, lessThan(24), reason: 'just left of the right group');
      expect(stageTop(tester), top - pictureLift);
      expect(tester.getSize(find.byType(TermStage)), size);
    });
  }

  testWidgets('stage 1200, panel open: the keys share the panel\'s line; the picture lifts $pictureLift',
      (tester) async {
    await openTerm(tester, width: 1200);
    final top = stageTop(tester);
    await toggleFromMenu(tester);
    await openPanel(tester);
    await tester.pump();
    final box = tester.getRect(find.byKey(const Key('composer-box')));
    final l = group(tester, left), r = group(tester, right);
    for (final g in [l, r]) {
      expect(g.overlaps(box), isFalse);
      expect(g.center.dy, closeTo(box.center.dy, 4));
    }
    expect(l.right, lessThanOrEqualTo(box.left));
    expect(r.left, greaterThanOrEqualTo(box.right));
    expect(stageTop(tester), top - pictureLift);
  });

  testWidgets('stage 1000, panel open: the key row is a line right above the panel; the picture lifts 120',
      (tester) async {
    await openTerm(tester, width: 1000);
    final top = stageTop(tester);
    final size = tester.getSize(find.byType(TermStage));
    await toggleFromMenu(tester);
    await openPanel(tester);
    await tester.pump();
    final panel = tester.getRect(find.byKey(const Key('composer-panel')));
    final l = group(tester, left), r = group(tester, right);
    for (final g in [l, r]) {
      expect(g.bottom, lessThanOrEqualTo(panel.top));
      expect(panel.top - g.bottom, lessThan(16));
    }
    expect(l.bottom, r.bottom);
    // The two groups at the two ends of the line.
    expect(l.left, closeTo(panel.left, 1));
    expect(r.right, closeTo(panel.right, 1));
    expect(stageTop(tester), top - 120);
    expect(tester.getSize(find.byType(TermStage)), size);
    // Only on a narrow stage with both on: the key row off, the lift is the panel's alone.
    await toggleFromMenu(tester);
    expect(stageTop(tester), top - pictureLift);
  });

  testWidgets('toggling the key row and crossing 1100 never sends a new view, never remounts the stage or panel '
      '(Review Focus 5)', (tester) async {
    // Both widths give the stage the same columns: any view now would be a remount's or the layout's own.
    await openTerm(tester, width: 1104);
    await pastViewPause(tester);
    final size = tester.getSize(find.byType(TermStage));
    final stageEl = tester.element(find.byType(TermStage));
    final cols = callsOf('view').last['cols'];
    term.calls.clear();
    await toggleFromMenu(tester);
    await pastViewPause(tester);
    await openPanel(tester);
    await tester.enterText(fieldFinder, 'draft');
    final panelState = tester.state(find.byType(ComposerPanel));
    await pastViewPause(tester);
    await tester.pumpWidget(wrap(window(1096), disableAnimations: true));
    await pastViewPause(tester);
    expect(tester.getSize(find.byType(TermStage)), Size(1096, size.height));
    // Narrow now: the row went above the panel.
    expect(tester.getRect(key('Esc')).bottom, lessThanOrEqualTo(tester.getRect(find.byType(ComposerPanel)).top));
    await toggleFromMenu(tester);
    await pastViewPause(tester);
    await toggleFromMenu(tester);
    await pastViewPause(tester);
    await tester.pumpWidget(wrap(window(1104), disableAnimations: true));
    await pastViewPause(tester);
    expect(identical(tester.state(find.byType(ComposerPanel)), panelState), isTrue,
        reason: 'the panel was remounted');
    expect(tester.widget<TextField>(fieldFinder).controller!.text, 'draft');
    s.currentRemote!.composer.collapse();
    await tester.pump();
    await toggleFromMenu(tester);
    await pastViewPause(tester);
    expect(callsOf('view'), isEmpty);
    expect(term.lastCols, cols);
    expect(identical(tester.element(find.byType(TermStage)), stageEl), isTrue, reason: 'the stage was remounted');
  });

  testWidgets('the panel is not remounted while the key row moves above it', (tester) async {
    await openTerm(tester, width: 1000);
    await openPanel(tester);
    await tester.enterText(fieldFinder, 'draft');
    final panelState = tester.state(find.byType(ComposerPanel));
    await toggleFromMenu(tester);
    await tester.pump();
    expect(key('Esc'), findsOneWidget);
    expect(identical(tester.state(find.byType(ComposerPanel)), panelState), isTrue);
    expect(tester.widget<TextField>(fieldFinder).controller!.text, 'draft');
  });

  testWidgets('an app session: no 按键排 in its menu, no key row on its stage', (tester) async {
    s.setTermKeyRow(true);
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(window(1200), disableAnimations: true));
    await tester.runAsync(() async {
      s.openOrSwitch('111', 'Safari', 'Safari');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    port.emit(const ReadyEvent(1, 'Safari'));
    port.emit(WindowsEvent(1, [
      const RemoteWindow(
        id: 5, parent: 0, kind: WindowKind.normal, title: 'w5', rect: Rect.fromLTWH(0, 0, 400, 328), titleBar: 28,
        resizable: true, focused: true, texture: 42, visible: Rect.fromLTWH(0, 0, 1, 1)),
    ]));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
    expect(key('Esc'), findsNothing);
    for (final corner in ['traffic', 'session-menu']) {
      await tester.tap(find.byKey(Key(corner)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('term-key-row')), findsNothing, reason: corner);
      expect(find.text('按键排'), findsNothing, reason: corner);
      s.closeCorner();
      await tester.pumpAndSettle();
    }
  });

  List<Object?> typed() => [for (final c in callsOf('type')) c['text']];

  testWidgets('⌃ then C on the keyboard sends Ctrl-C; the ⌃ is used up', (tester) async {
    await openTerm(tester);
    await toggleFromMenu(tester);
    await tester.tap(find.byKey(const Key('term-grid')));
    await tester.pump();
    term.calls.clear();
    await tester.tap(key('Ctrl'));
    await tester.pump();
    expect(keys(), isEmpty, reason: 'the ⌃ alone sends nothing');
    expect(stageFocused(tester), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(keys(), [
      ['Ctrl-C'],
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(typed(), ['c'], reason: 'the next C is plain');
  });

  testWidgets('⌃ then a key of the row (↑): the key goes as it is and the ⌃ goes out', (tester) async {
    await openTerm(tester);
    await toggleFromMenu(tester);
    term.calls.clear();
    await tester.tap(key('Ctrl'));
    await tester.pump();
    await tester.tap(key('Up'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('term-grid')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(keys(), [
      ['Up'],
    ]);
    expect(typed(), ['c']);
  });

  testWidgets('⌃ tapped twice is off again; while on it is outlined in the accent', (tester) async {
    await openTerm(tester);
    await toggleFromMenu(tester);
    Color side() => (tester.widget<Material>(find.descendant(of: key('Ctrl'), matching: find.byType(Material))).shape!
            as RoundedRectangleBorder)
        .side
        .color;
    final off = side();
    await tester.tap(key('Ctrl'));
    await tester.pump();
    expect(side(), isNot(off));
    await tester.tap(key('Ctrl'));
    await tester.pump();
    expect(side(), off);
    await tester.tap(find.byKey(const Key('term-grid')));
    await tester.pump();
    term.calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(typed(), ['c']);
  });

  testWidgets('a terminal never has the app key row, even with it on', (tester) async {
    s.prefs.appKeyRow = true;
    await openTerm(tester);
    expect(find.byType(AppKeyRow), findsNothing);
  });

  test('keyRowWideAt is 1100', () => expect(keyRowWideAt, 1100));
}
