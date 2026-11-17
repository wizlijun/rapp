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
      {'sid': 1, 'window': 3, 'cols': (800 / cw).floor(), 'rows': (480 / ch).floor(), 'fit': false},
    ]);
    await show(t, w: 900);
    await t.pump(const Duration(milliseconds: 200));
    expect(views(), hasLength(1));
    await t.pump(const Duration(milliseconds: 150));
    expect(views(), hasLength(2));
    expect(views().last, {'sid': 1, 'window': 3, 'cols': (900 / cw).floor(), 'rows': (480 / ch).floor(), 'fit': false});
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

  testWidgets('a small pane is scaled up to fill', (t) async {
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
}
