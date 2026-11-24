import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/composer_float.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/ui/tokens.dart';

void main() {
  const stage = Size(800, 600), panel = Size(720, 70);

  test('default: bottom centre, 8 up', () {
    expect(composerTopLeft(defaultComposerAt, stage, panel), const Offset(40, 522));
  });

  test('clamped to 8 from every edge', () {
    expect(composerTopLeft(const InputPoint(1, 0, fromBottom: true), stage, panel), const Offset(72, 522));
    expect(composerTopLeft(const InputPoint(0.5, 0), stage, panel), const Offset(40, 8));
    expect(composerTopLeft(const InputPoint(0, 300), stage, const Size(400, 70)), const Offset(8, 230));
  });

  test('resize clamps without rewriting', () {
    const at = InputPoint(0.9, 8, fromBottom: true);
    // centre 666 → left 306, clamped to 740 − 8 − 720 = 12; bottom 292 → top 222
    expect(composerTopLeft(at, const Size(740, 300), panel), const Offset(12, 222));
    // the same point on the big stage: centre 720 → left 520, clamped to 800 − 8 − 400 = 392
    expect(composerTopLeft(at, stage, const Size(400, 70)), const Offset(392, 522));
  });

  test('a panel taller than the stage keeps its top on stage', () {
    expect(composerTopLeft(defaultComposerAt, const Size(800, 60), panel).dy, 8);
  });

  test('the soft keyboard ([keyboard] up off the stage bottom) pushes the panel up to 8 above it', () {
    expect(composerTopLeft(defaultComposerAt, stage, panel, keyboard: 300), const Offset(40, 600 - 300 - 8 - 70));
    // A panel already clear of the keyboard stays where it is.
    expect(composerTopLeft(const InputPoint(0.5, 0), stage, panel, keyboard: 300), const Offset(40, 8));
  });

  group('pull down to collapse (G4)', () {
    late RemoteSession rs;
    var closed = 0;
    final placed = <InputPoint?>[];

    setUp(() {
      rs = RemoteSession(1, 'Safari');
      closed = 0;
      placed.clear();
    });
    tearDown(() => rs.dispose());

    void pullTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
          try {
            await body(tester);
          } finally {
            tester.view.reset();
            debugDefaultTargetPlatformOverride = null;
          }
        });

    final grip = find.byKey(const Key('composer-grip'));
    final body = find.byKey(const Key('body'));
    final text = find.byKey(const Key('text'));

    Future<void> show(WidgetTester tester, TargetPlatform platform, {bool pull = true, InputPoint? at, double keyboard = 0}) async {
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      final cur = ValueNotifier<InputPoint?>(at);
      await tester.pumpWidget(MaterialApp(
        theme: themeDataFor(RappTheme.matrix),
        home: Material(
          child: ValueListenableBuilder<InputPoint?>(
            valueListenable: cur,
            builder: (_, at, _) => FloatingComposer(
            session: rs,
            at: at,
            onPlace: (p) {
              placed.add(p);
              cur.value = p;
            },
            keyboard: keyboard,
            onPullClose: pull ? () => closed++ : null,
            child: SizedBox(
              height: 60,
              child: Column(children: [
                Container(key: const Key('body'), height: 20, color: Colors.red),
                MetaData(
                  metaData: composerTextArea,
                  behavior: HitTestBehavior.translucent,
                  child: SizedBox(key: const Key('text'), height: 40, width: double.infinity),
                ),
              ]),
            ),
          ),
          ),
        ),
      ));
      await tester.pump();
    }

    // Touch drag from [from] by each step [every] apart (real timestamps, so a fling has a velocity).
    Future<TestGesture> drag(WidgetTester tester, Offset from, List<double> dys,
        {bool lift = true, Duration every = const Duration(milliseconds: 16)}) async {
      var t = Duration.zero;
      final g = await tester.startGesture(from);
      for (final dy in dys) {
        t += every;
        await g.moveBy(Offset(0, dy), timeStamp: t);
        await tester.pump(every);
      }
      if (lift) {
        await g.up(timeStamp: t);
        await tester.pump();
        await tester.pump(kDoubleTapTimeout); // the grip also waits for a second tap
      }
      return g;
    }

    double top(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('composer-grip'))).dy;

    pullTest('panel high up: dragging down 100 moves it, no collapse', (tester) async {
      await show(tester, TargetPlatform.iOS, at: const InputPoint(0.5, 300));
      final y = top(tester);
      await drag(tester, tester.getCenter(grip), [50, 50]);
      expect(top(tester), closeTo(y + 100, 1));
      expect(closed, 0);
      expect(placed, hasLength(1));
    });

    pullTest('panel at lowest: drag down 80, release -> collapsed; place unchanged', (tester) async {
      await show(tester, TargetPlatform.iOS);
      final y = top(tester);
      final g = await drag(tester, tester.getCenter(grip), [40, 40], lift: false);
      expect(top(tester), closeTo(y + 80, 1), reason: 'follows the finger 1:1');
      await g.up(timeStamp: const Duration(milliseconds: 32));
      await tester.pump();
      await tester.pump(kDoubleTapTimeout);
      expect(closed, 1);
      expect(placed, isEmpty);
    });

    pullTest('at lowest: down 40 springs back, open, place unchanged', (tester) async {
      await show(tester, TargetPlatform.iOS);
      final y = top(tester);
      final g = await drag(tester, tester.getCenter(grip), [20, 20],
          lift: false, every: const Duration(milliseconds: 300)); // slow: no fling
      await g.up(timeStamp: const Duration(milliseconds: 600));
      await tester.pump();
      expect(closed, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(top(tester), greaterThan(y));
      expect(top(tester), lessThan(y + 40));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(kDoubleTapTimeout);
      expect(top(tester), closeTo(y, 0.5));
      expect(placed, isEmpty);
    });

    pullTest('at lowest: fast fling down 30 -> collapsed', (tester) async {
      await show(tester, TargetPlatform.iOS);
      await drag(tester, tester.getCenter(grip), [10, 10, 10], every: const Duration(milliseconds: 5));
      expect(closed, 1);
    });

    pullTest('drag that started high, reaches the bottom and goes 80 further -> collapsed', (tester) async {
      await show(tester, TargetPlatform.iOS, at: const InputPoint(0.5, 300));
      final y = top(tester);
      final room = 600 - 8 - 80 - y; // the panel's bottom is at 600-8 when lowest; it is 80 tall
      await drag(tester, tester.getCenter(grip), [room, 30, 30, 20]);
      expect(closed, 1);
      expect(placed, hasLength(1), reason: 'the lowest place it was dragged to, never the overshoot');
      expect(placed.single!.inContent(const Size(800, 600)).dy, closeTo(592, 0.5));
    });

    pullTest('keyboard 300, from the default place: pull 80 -> collapsed, nothing saved', (tester) async {
      await show(tester, TargetPlatform.iOS, keyboard: 300);
      await drag(tester, tester.getCenter(grip), [40, 40]);
      expect(closed, 1);
      expect(placed, isEmpty);
    });

    pullTest('keyboard 300, from the default place: pull 40 springs back, nothing saved', (tester) async {
      await show(tester, TargetPlatform.iOS, keyboard: 300);
      final y = top(tester);
      await drag(tester, tester.getCenter(grip), [20, 20], every: const Duration(milliseconds: 300));
      expect(closed, 0);
      expect(placed, isEmpty);
      expect(top(tester), closeTo(y, 0.5));
    });

    pullTest('keyboard 300, start high, drag into the bottom and further: saved as the true lowest place', (tester) async {
      await show(tester, TargetPlatform.iOS, at: const InputPoint(0.5, 100), keyboard: 300);
      final room = 600 - 300 - 8 - 80 - top(tester);
      await drag(tester, tester.getCenter(grip), [room, 40, 40]);
      expect(closed, 1);
      expect(placed, hasLength(1));
      expect(placed.single!.fromBottom, isTrue);
      expect(placed.single!.dy, composerMargin);
    });

    pullTest('reopened during a pull-close: the panel springs back, and a small drag does not collapse', (tester) async {
      await show(tester, TargetPlatform.iOS);
      final y = top(tester);
      await drag(tester, tester.getCenter(grip), [40, 40]);
      expect(closed, 1);
      await tester.pump(const Duration(milliseconds: 100));
      rs.composer.open = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(top(tester), closeTo(y, 0.5));
      await drag(tester, tester.getCenter(grip), [10]);
      expect(closed, 1);
    });

    pullTest('pull starting in the editor text: no collapse', (tester) async {
      await show(tester, TargetPlatform.iOS);
      await drag(tester, tester.getCenter(text), [40, 40, 40]);
      expect(closed, 0);
      expect(placed, isEmpty);
    });

    pullTest('a pull on the body outside the text collapses too', (tester) async {
      await show(tester, TargetPlatform.iOS);
      await drag(tester, tester.getCenter(body), [40, 40]);
      expect(closed, 1);
    });

    pullTest('iOS: no composer-grip-close, grip stays centred', (tester) async {
      await show(tester, TargetPlatform.iOS);
      expect(find.byKey(const Key('composer-grip-close')), findsNothing);
      expect(tester.getCenter(grip).dx, 400);
    });

    pullTest('macOS: no composer-grip-close, and no pull', (tester) async {
      await show(tester, TargetPlatform.macOS, pull: false);
      expect(find.byKey(const Key('composer-grip-close')), findsNothing);
      final y = top(tester);
      await drag(tester, tester.getCenter(grip), [40, 40]);
      expect(top(tester), closeTo(y, 0.5));
      expect(closed, 0);
    });
  });

  group('a generic block (Task 4)', () {
    late RemoteSession rs;
    final placed = <InputPoint?>[];
    final block = find.byKey(const Key('blk'));
    final grip = find.byKey(const Key('composer-grip'));

    setUp(() {
      rs = RemoteSession(1, 'Safari');
      placed.clear();
    });
    tearDown(() => rs.dispose());

    Future<void> pump(WidgetTester tester,
        {InputPoint? at, bool grip = true, double childH = 60, double childW = 0, Widget? inner}) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cur = ValueNotifier<InputPoint?>(at);
      await tester.pumpWidget(MaterialApp(
        theme: themeDataFor(RappTheme.matrix),
        home: Material(
          child: ValueListenableBuilder<InputPoint?>(
            valueListenable: cur,
            builder: (_, at, _) => FloatingComposer(
              session: rs,
              at: at,
              grip: grip,
              onPlace: (p) {
                placed.add(p);
                cur.value = p;
              },
              child: inner ?? ColoredBox(key: const Key('blk'), color: Colors.red, child: SizedBox(height: childH)),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('no × on any platform: composer-grip-close is never built', (tester) async {
      for (final p in [TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = p;
        await pump(tester);
        expect(find.byKey(const Key('composer-grip-close')), findsNothing, reason: '$p');
        expect(tester.getCenter(grip).dx, 400);
      }
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('at null uses defaultAt; a drag saves through onPlace; double-tap gives null', (tester) async {
      await pump(tester);
      final y = tester.getBottomLeft(block).dy;
      expect(y, 592); // defaultComposerAt: 8 up
      await tester.dragFrom(tester.getCenter(grip), const Offset(-100, -200));
      await tester.pump(kDoubleTapTimeout);
      expect(placed, hasLength(1));
      expect(placed.single, isNotNull);
      expect(tester.getBottomLeft(block).dy, closeTo(y - 200, 1));
      await tester.tap(grip);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(grip);
      await tester.pump();
      expect(placed.last, isNull);
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('at given wins over defaultAt', (tester) async {
      await pump(tester, at: const InputPoint(0.5, 100, fromBottom: true));
      expect(tester.getBottomLeft(block).dy, 500);
    });

    testWidgets('grip false: no composer-grip, the block is only the child', (tester) async {
      await pump(tester, grip: false);
      expect(grip, findsNothing);
      expect(tester.getRect(block), const Rect.fromLTWH(40, 532, 720, 60));
    });

    testWidgets('a drag starting inside composerNoDrag does not move the block', (tester) async {
      await pump(tester,
          inner: Column(mainAxisSize: MainAxisSize.min, children: [
            ColoredBox(key: const Key('blk'), color: Colors.red, child: const SizedBox(height: 30, width: double.infinity)),
            MetaData(
              metaData: composerNoDrag,
              behavior: HitTestBehavior.translucent,
              child: const SizedBox(key: Key('nd'), height: 40, width: double.infinity),
            ),
          ]));
      final y = tester.getTopLeft(block).dy;
      await tester.dragFrom(tester.getCenter(find.byKey(const Key('nd'))), const Offset(0, -150));
      await tester.pump(kDoubleTapTimeout);
      expect(placed, isEmpty);
      expect(tester.getTopLeft(block).dy, y);
      // outside the marker a drag still moves it
      await tester.dragFrom(tester.getCenter(block), const Offset(0, -150));
      await tester.pump(kDoubleTapTimeout);
      expect(placed, hasLength(1));
    });

    testWidgets('a held touch inside composerNoDrag does not move the block either', (tester) async {
      await pump(tester,
          inner: MetaData(
            metaData: composerNoDrag,
            behavior: HitTestBehavior.translucent,
            child: MetaData(
              metaData: composerTextArea,
              behavior: HitTestBehavior.translucent,
              child: const ColoredBox(key: Key('blk'), color: Colors.red, child: SizedBox(height: 40, width: double.infinity)),
            ),
          ));
      final g = await tester.startGesture(tester.getCenter(block));
      await tester.pump(const Duration(milliseconds: 400));
      await g.moveBy(const Offset(0, -150));
      await g.up();
      await tester.pump(kDoubleTapTimeout);
      expect(placed, isEmpty);
    });

    testWidgets('a growing child keeps the bottom centre where it was', (tester) async {
      await pump(tester, childH: 60);
      final before = tester.getRect(block).bottomCenter;
      await pump(tester, childH: 200);
      expect(tester.getRect(block).bottomCenter, before);
    });
  });
}
