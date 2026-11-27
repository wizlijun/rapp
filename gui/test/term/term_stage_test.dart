import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_layout.dart';
import 'package:rapp/term/term_model.dart';
import 'package:rapp/term/term_painter.dart';
import 'package:rapp/term/term_select.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

TermScreen scr(List<String> rows,
        {int rev = 1, int? hist, int? limit, bool alt = false, int? cols, Set<int> wrapped = const {}}) =>
    TermScreen(
      pane: '%3',
      rev: rev,
      cols: cols ?? 40,
      rows: rows.length,
      cx: 0,
      cy: 0,
      cursor: true,
      alt: alt,
      full: true,
      more: false,
      lines: [for (var i = 0; i < rows.length; i++) (i, rows[i])],
      hist: hist,
      limit: limit,
      wrapped: wrapped,
    );

RemoteWindow pane(int id) => RemoteWindow(
      id: id,
      parent: 0,
      kind: WindowKind.normal,
      title: 'p$id',
      rect: Rect.zero,
      titleBar: 0,
      resizable: false,
      focused: false,
      texture: null,
      visible: Rect.zero,
    );

void main() {
  late Directory tmp;
  late MainState state;
  late RemoteSession session;
  late FakeTermSessionPort port;
  late TermModel model;
  final metrics = TermMetrics.measure(termTextStyle(themeDataFor(RappTheme.matrix).extension<RappTokens>()!));
  final cw = metrics.cellW, ch = metrics.cellH;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('term_stage_test');
    state = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs());
    session = RemoteSession(1, 'term')..apply(WindowsEvent(1, [pane(3)]));
    model = TermModel()..expect('%3');
    port = FakeTermSessionPort()..seed(1, model: model);
  });
  tearDown(() {
    state.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester t, {double w = 800, double h = 480}) async {
    await t.pumpWidget(wrap(SizedBox(
      width: w,
      height: h,
      child: TermStage(state: state, session: session, port: port),
    )));
  }

  List<Map<String, Object?>> views() => [for (final c in port.calls) if (c.$1 == 'view') c.$2];

  TermPainter painter(WidgetTester t) =>
      t.widget<CustomPaint>(find.byKey(const Key('term-grid'))).painter! as TermPainter;

  // The centre of a cell on screen: the pane is laid out at the size that fits the stage, so a cell is the
  // size the painter draws it.
  Offset cell(WidgetTester t, int y, int x) {
    final m = painter(t).metrics;
    return t.getTopLeft(find.byKey(const Key('term-grid'))) + Offset((x + .5) * m.cellW, (y + .5) * m.cellH);
  }

  /// Scrolls the wheel by [rows] drawn rows (negative: back into history).
  Future<void> wheel(WidgetTester t, double rows) async {
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(p.hover(cell(t, 1, 1)));
    await t.sendEventToBinding(p.scroll(Offset(0, rows * painter(t).metrics.cellH)));
    await t.pump();
  }

  testWidgets('the stage asks for the size it can show, once, then after a 0.3 s pause', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await show(t);
    expect(views(), [
      {'sid': 1, 'window': 3, 'cols': (800 / cw).floor(), 'rows': (480 / ch).floor(), 'fit': true},
    ]);
    await show(t, w: 900);
    await t.pump(const Duration(milliseconds: 200));
    expect(views(), hasLength(1));
    await t.pump(const Duration(milliseconds: 150));
    expect(views(), hasLength(2));
    expect(views().last, {'sid': 1, 'window': 3, 'cols': (900 / cw).floor(), 'rows': (480 / ch).floor(), 'fit': true});
  });

  testWidgets('no view goes out before the session has a pane table', (t) async {
    session = RemoteSession(1, 'term');
    await show(t);
    expect(views(), isEmpty);
    session.apply(WindowsEvent(1, [pane(3)]));
    await t.pump();
    expect(views(), hasLength(1));
  });

  testWidgets('new output while reading history keeps the view and changes the banner', (t) async {
    final rows = [for (var i = 0; i < 10; i++) 'row $i'];
    model.apply(scr(rows, hist: 5, limit: 2000));
    model.applyHistory(const TermHistory(pane: '%3', before: 0, lines: ['h-5', 'h-4', 'h-3', 'h-2', 'h-1'], hist: 5));
    await show(t);
    expect(find.byKey(const Key('term-latest')), findsNothing);
    await wheel(t, -3);
    expect(model.offset, 3);
    expect(find.text('正在看历史 · 回到最新'), findsOneWidget);
    final top = painter(t).lineAtRow(0)!.text;
    expect(top, 'h-3');
    expect(port.calls.where((c) => c.$1 == 'fetchHistory'), isNotEmpty);

    model.apply(scr([...rows.skip(1), 'row 10'], rev: 2, hist: 6, limit: 2000));
    await t.pump();
    expect(find.text('有新输出 · 回到最新'), findsOneWidget);
    expect(painter(t).lineAtRow(0)!.text, top);

    await t.tap(find.byKey(const Key('term-latest')));
    await t.pump();
    expect(find.byKey(const Key('term-latest')), findsNothing);
    expect(model.offset, 0);
  });

  Future<void> ctrlShiftC(WidgetTester t) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  testWidgets('drag selects, the chip counts characters, ⌘C copies one joined line', (t) async {
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    model.apply(scr(['abcdefghij', 'klmnop', 'q'], cols: 10, wrapped: {0}));
    await show(t);

    final g = await t.startGesture(cell(t, 0, 0), kind: PointerDeviceKind.mouse);
    await g.moveTo(cell(t, 1, 3));
    await g.up();
    await t.pump();
    expect(find.text('选中了 14 个字 · 复制到本机'), findsOneWidget);

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      // Ctrl+Shift+C is the other platforms' copy, not macOS's.
      await ctrlShiftC(t);
      await t.pump();
      expect(copied, isEmpty);
      await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyC);
      await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    } else {
      await ctrlShiftC(t);
    }
    await t.pump();
    expect(copied, ['abcdefghijklmn']);
    expect(find.text('已复制'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 1100));
    expect(find.text('选中了 14 个字 · 复制到本机'), findsOneWidget);

    // The chip copies too; Esc clears the selection.
    await t.tap(find.byKey(const Key('term-copy')));
    await t.pump();
    expect(copied, hasLength(2));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byKey(const Key('term-copy')), findsNothing);
    await t.pump(const Duration(seconds: 2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS)..values.add(TargetPlatform.linux));

  testWidgets('double click selects a word, triple click the wrapped line', (t) async {
    model.apply(scr(['ab cd/ef gh', 'ij'], cols: 11, wrapped: {0}));
    await show(t);
    Future<void> click(Duration at) async {
      final p = TestPointer(2, PointerDeviceKind.mouse);
      await t.sendEventToBinding(p.down(cell(t, 0, 4), timeStamp: at));
      await t.sendEventToBinding(p.up(timeStamp: at + const Duration(milliseconds: 20)));
      await t.pump();
    }

    await click(const Duration(seconds: 10));
    expect(find.byKey(const Key('term-copy')), findsNothing);
    await click(const Duration(seconds: 10, milliseconds: 200));
    expect(find.text('选中了 5 个字 · 复制到本机'), findsOneWidget);
    await click(const Duration(seconds: 10, milliseconds: 400));
    expect(find.text('选中了 13 个字 · 复制到本机'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('shift+click after a plain click selects from the plain click', (t) async {
    model.apply(scr(['abcdefghij'], cols: 10));
    await show(t);
    Future<void> click(int x, Duration at) async {
      final p = TestPointer(3, PointerDeviceKind.mouse);
      await t.sendEventToBinding(p.down(cell(t, 0, x), timeStamp: at));
      await t.sendEventToBinding(p.up(timeStamp: at + const Duration(milliseconds: 20)));
      await t.pump();
    }

    await click(2, const Duration(seconds: 10));
    expect(find.byKey(const Key('term-copy')), findsNothing);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(5, const Duration(seconds: 12));
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(find.text('选中了 4 个字 · 复制到本机'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('a selection survives a refresh that does not touch its rows', (t) async {
    model.apply(scr(['aaaa', 'bbbb', 'cccc', 'dddd']));
    await show(t);
    final g = await t.startGesture(cell(t, 1, 0), kind: PointerDeviceKind.mouse);
    await g.moveTo(cell(t, 1, 3));
    await g.up();
    await t.pump();
    expect(find.text('选中了 4 个字 · 复制到本机'), findsOneWidget);

    model.apply(scr(['aaaa', 'bbbb', 'cccc', 'xxxx'], rev: 2));
    await t.pump();
    expect(find.text('选中了 4 个字 · 复制到本机'), findsOneWidget);

    model.apply(scr(['aaaa', 'bbbX', 'cccc', 'xxxx'], rev: 3));
    await t.pump();
    expect(find.byKey(const Key('term-copy')), findsNothing);
  });

  testWidgets('a selection follows its rows into history', (t) async {
    model.apply(scr(['r0', 'r1', 'r2', 'r3'], hist: 0, limit: 2000));
    await show(t);
    final g = await t.startGesture(cell(t, 2, 0), kind: PointerDeviceKind.mouse);
    await g.moveTo(cell(t, 2, 1));
    await g.up();
    await t.pump();
    expect(find.text('选中了 2 个字 · 复制到本机'), findsOneWidget);

    model.apply(scr(['r1', 'r2', 'r3', 'r4'], rev: 2, hist: 1, limit: 2000));
    await t.pump();
    final s = painter(t).selection!;
    expect((s.anchor.y, s.anchor.x, s.head.y, s.head.x), (1, 0, 1, 1));
  });

  testWidgets('a stage squeezed to nothing mid-drag keeps the base size and does not throw', (t) async {
    for (final (w, h) in [(800.0, 0.0), (0.0, 480.0), (0.0, 0.0)]) {
      model.apply(scr(['abc', 'def', 'ghi', 'jkl']));
      await show(t);
      final g = await t.startGesture(cell(t, 1, 0), kind: PointerDeviceKind.mouse);
      await g.moveTo(cell(t, 1, 2));
      await show(t, w: w, h: h);
      expect(painter(t).scale, 1.0, reason: '$w x $h');
      expect(painter(t).metrics.style.fontSize, 14, reason: '$w x $h');
      await g.moveTo(const Offset(5, 500));
      // The edge-scroll timer ticks on a stage with no size too.
      await t.pump(const Duration(milliseconds: 120));
      await g.up();
      await t.pump();
      expect(t.takeException(), isNull, reason: '$w x $h');
    }
  });

  testWidgets('a stage squeezed to a sliver does not throw on drag or scroll', (t) async {
    for (final (w, h) in [(800.0, 1.0), (1.0, 480.0)]) {
      model.apply(scr(['abc', 'def', 'ghi', 'jkl']));
      await show(t, w: w, h: h);
      final before = model.offset;
      final at = t.getCenter(find.byKey(const Key('term-grid')));
      final g = await t.startGesture(at, kind: PointerDeviceKind.mouse);
      await g.moveTo(at + const Offset(0, 0.4));
      await t.pump(const Duration(milliseconds: 120));
      await g.up();
      final ptr = TestPointer(7, PointerDeviceKind.mouse);
      await t.sendEventToBinding(ptr.hover(at));
      await t.sendEventToBinding(ptr.scroll(const Offset(30, 0)));
      await t.pump();
      expect(t.takeException(), isNull, reason: '$w x $h');
      expect(model.offset, before, reason: '$w x $h');
    }
  });

  testWidgets('only rows that changed are recorded again', (t) async {
    model.apply(scr(['a', 'b', 'c', 'd']));
    await show(t);
    final cache = painter(t).cache;
    expect(cache.recorded, 4);
    model.apply(scr(['a', 'B', 'c', 'd'], rev: 2));
    await t.pump();
    expect(cache.recorded, 5);
  });

  testWidgets('a rebuild with an equal theme keeps the recorded rows', (t) async {
    model.apply(scr(['a', 'b', 'c', 'd']));
    await show(t);
    final cache = painter(t).cache;
    expect(cache.recorded, 4);
    final tokens0 = RappTokens.of(t.element(find.byType(TermStage)));
    // The app rebuilds its MaterialApp with fresh, equal tokens on every MainState change; the theme
    // animation hands them on after half its time.
    await show(t);
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(identical(RappTokens.of(t.element(find.byType(TermStage))), tokens0), isFalse);
    expect(cache.recorded, 4);
    // A different theme is drawn again.
    state.prefs.theme = RappTheme.westworld;
    await t.pumpWidget(wrap(
      SizedBox(width: 800, height: 480, child: TermStage(state: state, session: session, port: port)),
      theme: RappTheme.westworld,
    ));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(cache.recorded, greaterThanOrEqualTo(8));
  });

  testWidgets('links are looked for only in the rows in view', (t) async {
    model.apply(scr([for (var i = 0; i < 10; i++) i == 5 ? 'see https://example.com/x' : 'row $i'],
        hist: 100, limit: 2000));
    await show(t);
    expect([for (final l in painter(t).links) (l.y, l.url)], [(5, 'https://example.com/x')]);
    await wheel(t, -50);
    expect(model.offset, 50);
    expect(painter(t).links, isEmpty);
    await wheel(t, 46);
    expect(model.offset, 4);
    expect([for (final l in painter(t).links) l.y], [5]);
  });

  testWidgets('the view asks with fit by default', (t) async {
    await show(t);
    expect(views().first['fit'], true);
  });

  testWidgets('turning fit off sends a view at once', (t) async {
    await show(t);
    await t.pump(const Duration(milliseconds: 400));
    state.setTermFit(false);
    await show(t);
    await t.pump();
    expect(views().last['fit'], false);
  });

  testWidgets('fit on and the pane is the asked size draws at 14', (t) async {
    model.apply(scr([for (var i = 0; i < 10; i++) 'r$i'], cols: 40));
    await show(t, w: 40 * cw, h: 10 * ch);
    expect(painter(t).metrics.style.fontSize, 14);
  });

  testWidgets('fit on and a smaller pane stays at 14', (t) async {
    model.apply(scr(['r0', 'r1'], cols: 10));
    await show(t, w: 40 * cw, h: 20 * ch);
    expect(painter(t).metrics.style.fontSize, 14);
  });

  testWidgets('fit on and a larger pane is scaled down', (t) async {
    model.apply(scr([for (var i = 0; i < 60; i++) 'r$i'], cols: 200));
    await show(t, w: 600, h: 400);
    expect(painter(t).metrics.style.fontSize, lessThan(14));
  });

  testWidgets('a small pane is scaled up to fill', (t) async {
    state.prefs.termFit = false;
    model.apply(scr([for (var i = 0; i < 2; i++) 'r$i'], cols: 10));
    await show(t, w: 40 * cw, h: 20 * ch);
    // Laid out at four times the font size, not stretched.
    expect(painter(t).scale, 1);
    expect(painter(t).metrics.style.fontSize, closeTo(56, 1));
    expect(10 * painter(t).metrics.cellW, lessThanOrEqualTo(40 * cw + 0.5));
  });

  testWidgets('a large pane is scaled down', (t) async {
    model.apply(scr([for (var i = 0; i < 60; i++) 'r$i'], cols: 200));
    await show(t, w: 600, h: 400);
    final m = painter(t).metrics;
    expect(painter(t).scale, 1);
    expect(m.style.fontSize, lessThan(14));
    expect(200 * m.cellW, lessThanOrEqualTo(600 + 0.5));
    expect(60 * m.cellH, lessThanOrEqualTo(400 + 0.5));
  });

  testWidgets('no scaled note', (t) async {
    model.apply(scr([for (var i = 0; i < 60; i++) 'r$i'], cols: 200));
    await show(t, w: 600, h: 400);
    expect(find.byKey(const Key('term-scaled')), findsNothing);
    model.apply(scr(['small'], rev: 2, cols: 10));
    await t.pump();
    expect(find.byKey(const Key('term-scaled')), findsNothing);
  });

  testWidgets('selection maps to cells when scaled up', (t) async {
    state.prefs.termFit = false;
    model.apply(scr(['abcdefghij', 'klmnopqrst'], cols: 10));
    await show(t, w: 40 * cw, h: 20 * ch);
    expect(painter(t).metrics.style.fontSize, closeTo(56, 1));
    final g = await t.startGesture(cell(t, 0, 1), kind: PointerDeviceKind.mouse);
    await g.moveTo(cell(t, 0, 3));
    await g.up();
    await t.pump();
    final sel = painter(t).selection!;
    expect(selectionText(sel, model.lineAt, model.wrappedAt), 'bcd');
  });

  testWidgets('termPage: a page of history at a time (screen rows less one), down back to the latest', (t) async {
    model.apply(scr([for (var i = 0; i < 10; i++) 'row $i'], hist: 50, limit: 2000));
    await show(t);
    final page = session.termPage!;
    expect(page(true), isTrue);
    expect(model.offset, 9);
    expect(page(true), isTrue);
    expect(model.offset, 18);
    expect(page(false), isTrue);
    expect(page(false), isTrue);
    expect(model.offset, 0);
    expect(port.calls.where((c) => c.$1 == 'keys'), isEmpty);
  });

  testWidgets('termPage in the alternate screen: false (the program has the key), nothing scrolls', (t) async {
    model.apply(scr([for (var i = 0; i < 10; i++) 'row $i'], hist: 50, limit: 2000, alt: true));
    await show(t);
    expect(session.termPage!(true), isFalse);
    expect(model.offset, 0);
  });

  testWidgets('a scroll in the alternate screen does nothing', (t) async {
    model.apply(scr([for (var i = 0; i < 10; i++) 'row $i'], hist: 50, limit: 2000, alt: true));
    await show(t);
    await wheel(t, -3);
    expect(model.offset, 0);
    expect(find.byKey(const Key('term-latest')), findsNothing);
  });

  testWidgets('the device note shows for 3 seconds', (t) async {
    model.apply(scr(['a']));
    await show(t);
    model.fail('history read failed');
    await t.pump();
    expect(find.text('history read failed'), findsOneWidget);
    await t.pump(const Duration(seconds: 3, milliseconds: 100));
    expect(find.text('history read failed'), findsNothing);
  });

  testWidgets('a click focuses the stage and takes keys from the picture', (t) async {
    model.apply(scr(['a']));
    await show(t);
    final focus = Focus.of(t.element(find.byKey(const Key('term-grid'))));
    expect(focus.hasFocus, isFalse);
    await t.tap(find.byKey(const Key('term-grid')));
    await t.pump();
    expect(focus.hasFocus, isTrue);
    expect(state.pictureFocused, isNull);
  });
  testWidgets('a mouse drag in the strip below a short grid does not scroll', (t) async {
    model.apply(scr(['r0', 'r1', 'r2', 'r3'], hist: 100, limit: 2000));
    await show(t);
    await wheel(t, -10);
    expect(model.offset, 10);
    final below = t.getTopLeft(find.byKey(const Key('term-grid'))) + Offset(5, 4 * ch + 200);
    final g = await t.startGesture(cell(t, 1, 0), kind: PointerDeviceKind.mouse);
    await g.moveTo(below);
    await t.pump(const Duration(milliseconds: 220));
    await g.up();
    await t.pump();
    expect(model.offset, 10);
  });

  group('touch (iOS)', () {
    /// [body] as on an iPad; the override never outlives the test (Flutter asserts on a leaked one).
    Future<void> onIOS(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    // A pane that fills the 800x480 stage at the base size: row y is words `<letter><two digits>` 4 cells apart.
    final cols = (800 / cw).floor(), rows = (480 / ch).floor();
    String word(int y, int j) => '${String.fromCharCode(97 + y % 26)}${j.toString().padLeft(2, '0')}';
    final lines = [
      for (var y = 0; y < rows; y++) [for (var j = 0; j < cols ~/ 4; j++) word(y, j)].join(' '),
    ];

    /// Where the stage is on the screen: positions below are on the stage, as the zoom's are.
    Offset origin(WidgetTester t) => t.getTopLeft(find.byType(TermStage));
    Offset gridAt(WidgetTester t) => t.getTopLeft(find.byKey(const Key('term-grid'))) - origin(t);

    /// Two fingers [from] each side of [at] (on the stage) spread (or close) to [to] each side in one event batch.
    Future<void> pinch(WidgetTester t, {Offset at = const Offset(400, 240), double from = 100, double to = 200}) async {
      at += origin(t);
      final f1 = await t.createGesture(kind: PointerDeviceKind.touch, pointer: 21);
      final f2 = await t.createGesture(kind: PointerDeviceKind.touch, pointer: 22);
      await f1.down(at - Offset(from, 0));
      await f2.down(at + Offset(from, 0));
      final b = t.binding;
      b.handlePointerEvent(PointerMoveEvent(pointer: 21, kind: PointerDeviceKind.touch, position: at - Offset(to, 0)));
      b.handlePointerEvent(PointerMoveEvent(pointer: 22, kind: PointerDeviceKind.touch, position: at + Offset(to, 0)));
      await t.pump();
      await f1.up();
      await f2.up();
      await t.pump();
    }

    testWidgets('two fingers moving together scroll back through history', (t) async {
      await onIOS(() async {
        model.apply(scr([for (var i = 0; i < 10; i++) 'row $i'], hist: 100, limit: 2000));
        await show(t);
        final f1 = await t.createGesture(kind: PointerDeviceKind.touch, pointer: 11);
        final f2 = await t.createGesture(kind: PointerDeviceKind.touch, pointer: 12);
        await f1.down(const Offset(300, 100));
        await f2.down(const Offset(400, 100));
        final b = t.binding;
        b.handlePointerEvent(
            const PointerMoveEvent(pointer: 11, kind: PointerDeviceKind.touch, position: Offset(300, 160)));
        b.handlePointerEvent(
            const PointerMoveEvent(pointer: 12, kind: PointerDeviceKind.touch, position: Offset(400, 160)));
        await t.pump();
        await f1.up();
        await f2.up();
        await t.pump();
        expect(model.offset, closeTo(60 / ch, 1e-9));
        expect(find.byKey(const Key('term-copy')), findsNothing);
      });
    });

    testWidgets('one finger held 150 ms then dragged still selects', (t) async {
      await onIOS(() async {
        model.apply(scr(['abcdefghij', 'klmnop'], cols: 10));
        await show(t);
        final g = await t.startGesture(cell(t, 0, 0), kind: PointerDeviceKind.touch);
        await t.pump(const Duration(milliseconds: 160));
        await g.moveTo(cell(t, 0, 2));
        await g.moveTo(cell(t, 0, 3));
        await g.up();
        await t.pump();
        expect(selectionText(painter(t).selection!, model.lineAt, model.wrappedAt), 'abcd');
      });
    });

    testWidgets('zoomed: a one-finger drag pans, never selects', (t) async {
      await onIOS(() async {
        model.apply(scr(lines, cols: cols));
        await show(t);
        await pinch(t);
        expect(session.zoomOf(3).z, 2.0);
        final before = gridAt(t);
        final g = await t.startGesture(origin(t) + const Offset(400, 240), kind: PointerDeviceKind.touch);
        await g.moveTo(origin(t) + const Offset(380, 225));
        await g.moveTo(origin(t) + const Offset(350, 200));
        await g.up();
        await t.pump();
        expect(gridAt(t), offsetMoreOrLessEquals(before + const Offset(-50, -40)));
        expect(painter(t).selection, isNull);
        expect(find.byKey(const Key('term-copy')), findsNothing);
      });
    });

    testWidgets('zoomed: hold 500 ms then drag selects', (t) async {
      await onIOS(() async {
        model.apply(scr(lines, cols: cols));
        await show(t);
        await pinch(t);
        expect(session.zoomOf(3).z, 2.0);
        final before = gridAt(t);
        final g = await t.startGesture(origin(t) + const Offset(400, 240), kind: PointerDeviceKind.touch);
        await t.pump(const Duration(milliseconds: 510));
        await g.moveTo(origin(t) + const Offset(450, 240));
        await g.moveTo(origin(t) + const Offset(500, 240));
        await g.up();
        await t.pump();
        expect(gridAt(t), before);
        expect(painter(t).selection, isNotNull);
        expect(find.byKey(const Key('term-copy')), findsOneWidget);
      });
    });

    testWidgets('zoomed: a tap hits the cell it shows', (t) async {
      await onIOS(() async {
        model.apply(scr(lines, cols: cols));
        await show(t);
        final base = painter(t).metrics;
        await pinch(t);
        // Pan, so the grid is no longer where 2x about the centre put it.
        final g = await t.startGesture(origin(t) + const Offset(400, 240), kind: PointerDeviceKind.touch);
        await g.moveTo(origin(t) + const Offset(440, 260));
        await g.moveTo(origin(t) + const Offset(470, 290));
        await g.up();
        await t.pump();

        // Where the cells are: the zoom's rect for the base grid, cut into cells at twice the font.
        final zoom = session.zoomOf(3);
        expect(zoom.z, 2.0);
        final fit = Rect.fromLTWH(0, 0, cols * base.cellW, rows * base.cellH);
        final zfit = zoom.zfit(fit, const Size(800, 480));
        final big = TermMetrics.measure(base.style.copyWith(fontSize: base.style.fontSize! * 2));
        const at = Offset(523, 311);
        final y = ((at.dy - zfit.top) / big.cellH).floor(), x = ((at.dx - zfit.left) / big.cellW).floor();
        // A word's cell, not a gap.
        expect(x % 4, isNot(3));

        // A double tap selects the word under it.
        final p = TestPointer(31, PointerDeviceKind.touch);
        await t.sendEventToBinding(p.down(origin(t) + at, timeStamp: const Duration(seconds: 10)));
        await t.sendEventToBinding(p.up(timeStamp: const Duration(seconds: 10, milliseconds: 40)));
        await t.pump();
        await t.sendEventToBinding(p.down(origin(t) + at, timeStamp: const Duration(seconds: 10, milliseconds: 200)));
        await t.sendEventToBinding(p.up(timeStamp: const Duration(seconds: 10, milliseconds: 240)));
        await t.pump();
        expect(selectionText(painter(t).selection!, model.lineAt, model.wrappedAt), word(y, x ~/ 4));
        await t.pump(const Duration(seconds: 2));
      });
    });

    testWidgets('zoomed: a drag above a grid shorter than the stage scrolls back', (t) async {
      await onIOS(() async {
        model.apply(scr(['r0', 'r1', 'r2', 'r3'], hist: 100, limit: 2000));
        await show(t);
        await wheel(t, -10);
        expect(model.offset, 10);
        await pinch(t);
        expect(session.zoomOf(3).z, 2.0);
        // Pan the 2x grid (4 rows, far shorter than the stage) down off the stage's top.
        final g = await t.startGesture(origin(t) + const Offset(400, 240), kind: PointerDeviceKind.touch);
        await g.moveTo(origin(t) + const Offset(400, 290));
        await g.moveTo(origin(t) + const Offset(400, 340));
        await g.up();
        await t.pump();
        final top = gridAt(t).dy;
        expect(top, greaterThan(60));
        // Held in the grid, then dragged above it (still on the stage): back into history, a row every 50 ms.
        final d = await t.startGesture(origin(t) + Offset(400, top + 20), kind: PointerDeviceKind.touch);
        await t.pump(const Duration(milliseconds: 510));
        await d.moveTo(origin(t) + Offset(400, top - 10));
        await d.moveTo(origin(t) + Offset(400, top - 40));
        await t.pump(const Duration(milliseconds: 120));
        await d.up();
        await t.pump();
        expect(model.offset, greaterThan(10));
      });
    });

    testWidgets('zoomed: the grid drawn is exactly the zoom rect', (t) async {
      await onIOS(() async {
        // A pane laid out small: its font is not whole, its cells are rounded up.
        final big = [for (var i = 0; i < 60; i++) 'r$i'];
        model.apply(scr(big, cols: 110));
        await show(t, w: 600, h: 400);
        final base = painter(t).metrics;
        expect(base.cellH, isNot(base.style.fontSize));
        await pinch(t, at: const Offset(300, 200), to: 250);
        final zoom = session.zoomOf(3);
        expect(zoom.z, 2.5);
        final zfit = zoom.zfit(Rect.fromLTWH(0, 0, 110 * base.cellW, 60 * base.cellH), const Size(600, 400));
        final m = painter(t).metrics;
        expect(60 * m.cellH, moreOrLessEquals(zfit.height));
        expect(110 * m.cellW, moreOrLessEquals(zfit.width));
        expect(gridAt(t), offsetMoreOrLessEquals(zfit.topLeft));
      });
    });

    testWidgets('zooming never changes the requested rows and columns', (t) async {
      await onIOS(() async {
        model.apply(scr(lines, cols: cols));
        await show(t);
        await t.pump(const Duration(milliseconds: 400));
        final asked = views();
        expect(asked, isNotEmpty);
        await pinch(t, to: 300);
        expect(session.zoomOf(3).z, 3.0);
        expect(painter(t).metrics.style.fontSize, 42);
        await t.pump(const Duration(milliseconds: 400));
        expect(views(), asked);
      });
    });
  });
}
