import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';
import 'platform_helpers.dart';

void main() {
  testWidgets('ConfirmButton single tap does not fire', (t) async {
    var n = 0;
    await t.pumpWidget(
      wrap(ConfirmButton(label: '结束会话', onConfirmed: () => n++)),
    );
    await t.tap(find.text('结束会话'));
    await t.pump();
    expect(n, 0);
    expect(find.text('再点一次确认'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
  });
  testWidgets('second tap within 3s fires once', (t) async {
    var n = 0;
    await t.pumpWidget(
      wrap(ConfirmButton(label: '结束会话', onConfirmed: () => n++)),
    );
    await t.tap(find.text('结束会话'));
    await t.pump(const Duration(seconds: 2));
    await t.tap(find.text('再点一次确认'));
    await t.pump();
    expect(n, 1);
    expect(find.text('结束会话'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
  });
  testWidgets('resets after 3s', (t) async {
    var n = 0;
    await t.pumpWidget(
      wrap(ConfirmButton(label: '结束会话', onConfirmed: () => n++)),
    );
    await t.tap(find.text('结束会话'));
    await t.pump(const Duration(seconds: 3));
    expect(find.text('结束会话'), findsOneWidget);
    await t.tap(find.text('结束会话'));
    await t.pump();
    expect(n, 0);
    await t.pump(const Duration(seconds: 3));
  });
  testWidgets('RappButton is at least 48 tall', (t) async {
    await t.pumpWidget(wrap(RappButton.primary(label: '打开', onPressed: () {})));
    expect(t.getSize(find.byType(RappButton)).height, greaterThanOrEqualTo(48));
  });
  testWidgets('RappButton variants build, fire, and scale on press', (t) async {
    var n = 0;
    await t.pumpWidget(
      wrap(
        Column(
          children: [
            RappButton.primary(label: 'a', onPressed: () => n++),
            RappButton.secondary(label: 'b', onPressed: () => n++),
            RappButton.accent(label: 'c', onPressed: () => n++),
          ],
        ),
      ),
    );
    for (final l in ['a', 'b', 'c']) {
      await t.tap(find.text(l));
    }
    expect(n, 3);
    final g = await t.startGesture(t.getCenter(find.text('a')));
    await t.pump(const Duration(milliseconds: 100));
    expect(
      t
          .widget<AnimatedScale>(
            find.descendant(
              of: find.byType(RappButton).first,
              matching: find.byType(AnimatedScale),
            ),
          )
          .scale,
      0.97,
    );
    await g.up();
    await t.pump(const Duration(milliseconds: 100));
  });
  testWidgets('no press scale with reduced motion', (t) async {
    await t.pumpWidget(
      wrap(
        RappButton.primary(label: 'a', onPressed: () {}),
        disableAnimations: true,
      ),
    );
    final g = await t.startGesture(t.getCenter(find.text('a')));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await g.up();
  });
  testWidgets('keyboard: Enter arms, Enter again confirms', (t) async {
    var n = 0;
    await t.pumpWidget(
      wrap(ConfirmButton(label: '结束会话', onConfirmed: () => n++)),
    );
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    await t.pump();
    expect(find.text('再点一次确认'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(n, 1);
    await t.pump(const Duration(seconds: 3));
  });
  testWidgets('disabled button does not scale on press', (t) async {
    await t.pumpWidget(wrap(const RappButton.primary(label: 'a')));
    final g = await t.startGesture(t.getCenter(find.text('a')));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await g.up();
  });

  Widget onP(TargetPlatform p, Widget child) => MaterialApp(
        theme: themeDataFor(RappTheme.matrix, platform: p),
        home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: 300, child: child))),
      );
  final tk = tokensFor(RappTheme.matrix);
  Color labelColor(WidgetTester t, String s) => t.widget<Text>(find.text(s)).style!.color!;

  group('RappSwitchRow', () {
    testWidgets('tapping the label toggles', (t) async {
      bool? got;
      await t.pumpWidget(wrap(RappSwitchRow(label: '甲', value: false, onChanged: (v) => got = v)));
      await t.tap(find.text('甲'));
      expect(got, true);
    });
    testWidgets('tapping the switch calls once and the switch is 38x24', (t) async {
      var n = 0;
      await t.pumpWidget(wrap(RappSwitchRow(
          switchKey: const Key('sw'), label: '甲', value: false, onChanged: (_) => n++)));
      expect(t.getSize(find.ancestor(of: find.byKey(const Key('sw')), matching: find.byType(FittedBox))), const Size(38, 24));
      await t.tap(find.byKey(const Key('sw')));
      expect(n, 1);
    });
    testWidgets('onChanged null is inert and muted', (t) async {
      await t.pumpWidget(wrap(const RappSwitchRow(label: '甲', value: false)));
      await t.tap(find.text('甲'));
      expect(labelColor(t, '甲'), tk.muted);
    });
    testWidgets('dim mutes the label and note is muted', (t) async {
      await t.pumpWidget(wrap(RappSwitchRow(label: '甲', note: '乙', value: false, dim: true, onChanged: (_) {})));
      expect(labelColor(t, '甲'), tk.muted);
      expect(labelColor(t, '乙'), tk.muted);
      await t.pumpWidget(wrap(RappSwitchRow(label: '甲', value: false, onChanged: (_) {})));
      expect(labelColor(t, '甲'), tk.text);
    });
    for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
      testWidgets('row height $h on $p', (t) async {
        await onPlatform(p, () async {
          await t.pumpWidget(onP(p, RappSwitchRow(key: const Key('r'), label: '甲', value: false, onChanged: (_) {})));
          expect(t.getSize(find.byKey(const Key('r'))).height, h);
        });
      });
    }
  });

  group('RappCheckRow', () {
    testWidgets('tapping the label toggles; checkbox is left of the label', (t) async {
      bool? got;
      await t.pumpWidget(wrap(RappCheckRow(label: '甲', value: false, onChanged: (v) => got = v)));
      expect(t.getTopLeft(find.byType(Checkbox)).dx, lessThan(t.getTopLeft(find.text('甲')).dx));
      await t.tap(find.text('甲'));
      expect(got, true);
    });
    testWidgets('disabled is inert', (t) async {
      await t.pumpWidget(wrap(const RappCheckRow(label: '甲', value: false)));
      await t.tap(find.text('甲'));
      expect(labelColor(t, '甲'), tk.muted);
    });
    for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
      testWidgets('row height $h on $p', (t) async {
        await onPlatform(p, () async {
          await t.pumpWidget(onP(p, RappCheckRow(key: const Key('r'), label: '甲', value: false, onChanged: (_) {})));
          expect(t.getSize(find.byKey(const Key('r'))).height, h);
        });
      });
    }
  });

  group('RappChoice', () {
    testWidgets('icon colours and semantics', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(wrap(Column(mainAxisSize: MainAxisSize.min, children: [
        RappChoice(key: const Key('a'), label: '甲', selected: true, onTap: () {}),
        RappChoice(key: const Key('b'), label: '乙', selected: false, onTap: () {}),
      ])));
      Color ic(String k) => t.widget<Icon>(find.descendant(of: find.byKey(Key(k)), matching: find.byType(Icon))).color!;
      expect(ic('a'), tk.accent);
      expect(ic('b'), tk.muted);
      final d = t.getSemantics(find.byKey(const Key('a')));
      expect(d.flagsCollection.isInMutuallyExclusiveGroup, true);
      expect(d.flagsCollection.isChecked, CheckedState.isTrue);
      h.dispose();
    });
    testWidgets('dim mutes the label', (t) async {
      await t.pumpWidget(wrap(RappChoice(label: '甲', selected: false, dim: true, onTap: () {})));
      expect(labelColor(t, '甲'), tk.muted);
    });
    for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
      testWidgets('height $h on $p', (t) async {
        await onPlatform(p, () async {
          await t.pumpWidget(onP(p, Row(children: [RappChoice(key: const Key('r'), label: '甲', selected: true, onTap: () {})])));
          expect(t.getSize(find.byKey(const Key('r'))).height, h);
        });
      });
    }
  });

  group('RappDropdown', () {
    Widget dd({int? current = 2, bool selected = false, ValueChanged<int>? on, Key? key}) => onP(
          TargetPlatform.macOS,
          RappDropdown<int>(
            key: key ?? const Key('dd'),
            label: const Text('甲'),
            current: current,
            selected: selected,
            items: const [
              RappMenuItem(value: 1, label: '一'),
              RappMenuItem(value: 2, label: '二'),
            ],
            onSelected: on ?? (_) {},
          ),
        );
    BoxDecoration box(WidgetTester t) => t
        .widget<Container>(find.descendant(of: find.byKey(const Key('dd')), matching: find.byType(Container)).first)
        .decoration! as BoxDecoration;

    testWidgets('rests with a line border, then opens a menu ticking only the current row', (t) async {
      await t.pumpWidget(dd());
      expect((box(t).border! as Border).top.color, tk.line);
      expect(find.byKey(const Key('dd')), findsOneWidget);
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget);
      final tick = t.getCenter(find.byIcon(Icons.check)).dy;
      expect((tick - t.getCenter(find.text('二')).dy).abs() < 1, true);
      expect(t.widget<Icon>(find.byIcon(Icons.check)).size, 18);
      expect(t.widget<Text>(find.text('二')).style?.fontWeight, isNull);
    });
    testWidgets('while open the box uses the selected style', (t) async {
      await t.pumpWidget(dd());
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      expect((box(t).border! as Border).top.color, tk.text);
    });
    testWidgets('selected uses the raised box with a text border', (t) async {
      await t.pumpWidget(dd(selected: true));
      expect(box(t).color, tk.raise.first);
      expect((box(t).border! as Border).top.color, tk.text);
    });
    testWidgets('choosing a row calls onSelected with its value', (t) async {
      final got = <int>[];
      await t.pumpWidget(dd(on: got.add));
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      await t.tap(find.text('一'));
      await t.pumpAndSettle();
      expect(got, [1]);
      expect(find.text('一'), findsNothing);
    });
    testWidgets('without current there is no tick column', (t) async {
      await t.pumpWidget(dd(current: null));
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsNothing);
      final x0 = t.getTopLeft(find.text('一')).dx;
      await t.tapAt(const Offset(700, 500));
      await t.pumpAndSettle();
      await t.pumpWidget(dd());
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.text('一')).dx - x0, 26);
    });
    testWidgets('the popup has a text-colour side', (t) async {
      await t.pumpWidget(dd());
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is Material && w.shape is RoundedRectangleBorder && (w.shape! as RoundedRectangleBorder).side.color == tk.text),
        findsOneWidget,
      );
    });
    testWidgets('the arrow is 18 and muted', (t) async {
      await t.pumpWidget(dd());
      final a = t.widget<Icon>(find.byIcon(Icons.arrow_drop_down));
      expect((a.size, a.color), (18.0, tk.muted));
    });
    for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
      testWidgets('box height $h on $p', (t) async {
        await onPlatform(p, () async {
          await t.pumpWidget(onP(p, Row(children: [
            RappDropdown<int>(key: const Key('dd'), label: const Text('甲'), items: const [], onSelected: (_) {}),
          ])));
          expect(t.getSize(find.byKey(const Key('dd'))).height, h);
        });
      });
    }
    testWidgets('a long label stays within 280 wide and ellipsizes', (t) async {
      await t.pumpWidget(onP(TargetPlatform.macOS, Row(children: [
        RappDropdown<int>(
          label: const Text('甲'),
          items: [RappMenuItem(value: 1, label: '很长的标题' * 40)],
          onSelected: (_) {},
        ),
      ])));
      await t.tap(find.text('甲'));
      await t.pumpAndSettle();
      final row = find.ancestor(of: find.textContaining('很长的标题'), matching: find.byType(InkWell)).first;
      expect(t.getSize(row).width, lessThanOrEqualTo(280));
      expect(t.renderObject<RenderParagraph>(find.textContaining('很长的标题')).didExceedMaxLines, true);
    });
    testWidgets('an action menu box stays plain while its menu is open', (t) async {
      await t.pumpWidget(dd(current: null));
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      expect((box(t).border! as Border).top.color, tk.line);
      expect(DefaultTextStyle.of(t.element(find.text('甲'))).style.fontWeight, isNot(FontWeight.w600));
    });
    testWidgets('menu rows are control height', (t) async {
      await onPlatform(TargetPlatform.iOS, () async {
        await t.pumpWidget(onP(TargetPlatform.iOS, RappDropdown<int>(
          label: const Text('甲'),
          items: const [RappMenuItem(value: 1, label: '一')],
          onSelected: (_) {},
        )));
        await t.tap(find.text('甲'));
        await t.pumpAndSettle();
        expect(t.getSize(find.ancestor(of: find.text('一'), matching: find.byType(InkWell)).first).height, 48);
      });
    });
  });
}
