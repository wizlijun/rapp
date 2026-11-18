import 'dart:ui' show CheckedState, Tristate;

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

  group('RappButton.quiet', () {
    testWidgets('muted ink, no border, transparent fill', (t) async {
      await t.pumpWidget(wrap(RappButton.quiet(label: '取消', onPressed: () {})));
      final b = t.widget<TextButton>(find.byType(TextButton));
      final st = b.style!;
      expect(st.foregroundColor!.resolve({}), tk.muted);
      expect(st.side, isNull);
      expect(st.backgroundColor!.resolve({}), Colors.transparent);
    });
    for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
      testWidgets('height $h on $p', (t) async {
        await onPlatform(p, () async {
          await t.pumpWidget(onP(p, RappButton.quiet(key: const Key('q'), label: '取消', onPressed: () {})));
          expect(t.getSize(find.byKey(const Key('q'))).height, h);
        });
      });
    }
    testWidgets('scales to 0.97 while pressed', (t) async {
      await t.pumpWidget(wrap(RappButton.quiet(label: '取消', onPressed: () {})));
      final g = await t.startGesture(t.getCenter(find.text('取消')));
      await t.pump(const Duration(milliseconds: 100));
      expect(t.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 0.97);
      await g.up();
      await t.pump(const Duration(milliseconds: 100));
    });
    for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
      testWidgets('icon button is square $h on $p', (t) async {
        await onPlatform(p, () async {
          await t.pumpWidget(onP(p, Center(child: RappButton.primary(key: const Key('i'), label: 'x', icon: Icons.add, onPressed: () {}))));
          expect(t.getSize(find.byKey(const Key('i'))), Size(h, h));
        });
      });
    }
  });

  group('RappSwitchRow', () {
    testWidgets('tapping the label toggles', (t) async {
      bool? got;
      await t.pumpWidget(wrap(RappSwitchRow(label: '甲', value: false, onChanged: (v) => got = v)));
      await t.tap(find.text('甲'));
      expect(got, true);
    });
    testWidgets('tapping the switch calls once', (t) async {
      var n = 0;
      await t.pumpWidget(wrap(RappSwitchRow(
          switchKey: const Key('sw'), label: '甲', value: false, onChanged: (_) => n++)));
      await t.tap(find.byKey(const Key('sw')));
      expect(n, 1);
    });
    testWidgets('the switch is exactly 38x24 on macOS', (t) async {
      await onPlatform(TargetPlatform.macOS, () async {
        await t.pumpWidget(onP(TargetPlatform.macOS,
            RappSwitchRow(switchKey: const Key('sw'), label: '甲', value: false, onChanged: (_) {})));
        expect(t.getSize(find.ancestor(of: find.byKey(const Key('sw')), matching: find.byType(FittedBox))),
            const Size(38, 24));
      });
    });
    testWidgets('onChanged null is inert and muted', (t) async {
      await t.pumpWidget(wrap(const RappSwitchRow(switchKey: Key('sw'), label: '甲', value: false)));
      await t.tap(find.text('甲'));
      // Nothing to call: neither the row nor the switch has a handler.
      expect(t.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
      expect(t.widget<Switch>(find.byKey(const Key('sw'))).onChanged, isNull);
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
    testWidgets('tapping the checkbox itself fires once', (t) async {
      var n = 0;
      await t.pumpWidget(wrap(RappCheckRow(label: '甲', value: false, onChanged: (_) => n++)));
      await t.tap(find.byType(Checkbox));
      expect(n, 1);
    });
    testWidgets('disabled is inert', (t) async {
      await t.pumpWidget(wrap(const RappCheckRow(label: '甲', value: false)));
      await t.tap(find.text('甲'));
      expect(t.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
      expect(t.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
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
      expect(t.renderObject<RenderParagraph>(find.text('二')).text.style?.fontWeight, isNot(FontWeight.w600));
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
    for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
      testWidgets('menu rows are $h on $p', (t) async {
        await onPlatform(p, () async {
          await t.pumpWidget(onP(p, RappDropdown<int>(
            label: const Text('甲'),
            items: const [RappMenuItem(value: 1, label: '一')],
            onSelected: (_) {},
          )));
          await t.tap(find.text('甲'));
          await t.pumpAndSettle();
          expect(t.getSize(find.ancestor(of: find.text('一'), matching: find.byType(InkWell)).first).height, h);
        });
      });
    }
    testWidgets('empty items do not open a menu', (t) async {
      await t.pumpWidget(onP(TargetPlatform.macOS,
          RappDropdown<int>(key: const Key('dd'), label: const Text('甲'), items: const [], onSelected: (_) {})));
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      expect(find.byType(PopupMenuItem<int>), findsNothing);
      expect(find.byType(Scrollable), findsNothing);
    });
    testWidgets('semantics: label, enabled, selected only with a set current', (t) async {
      final h = t.ensureSemantics();
      Future<SemanticsData> data(Widget w) async {
        await t.pumpWidget(onP(TargetPlatform.macOS, w));
        return t.getSemantics(find.byKey(const Key('dd'))).getSemanticsData();
      }
      RappDropdown<int> d({int? current, bool selected = false, bool enabled = true, String? label}) => RappDropdown<int>(
            key: const Key('dd'),
            label: const Text('甲'),
            current: current,
            selected: selected,
            enabled: enabled,
            semanticLabel: label,
            items: const [RappMenuItem(value: 1, label: '一')],
            onSelected: (_) {},
          );
      var s = await data(d(current: 1, selected: true, label: '设备'));
      expect(s.label, '设备');
      expect(s.flagsCollection.isSelected, Tristate.isTrue);
      expect(s.flagsCollection.isEnabled, Tristate.isTrue);
      s = await data(d(selected: true, enabled: false));
      expect(s.flagsCollection.isSelected, isNot(Tristate.isTrue));
      expect(s.flagsCollection.isEnabled, Tristate.isFalse);
      h.dispose();
    });
    testWidgets('center puts the label in the middle of a wider box', (t) async {
      await t.pumpWidget(onP(TargetPlatform.macOS, Row(children: [
        RappDropdown<int>(
            key: const Key('dd'),
            minWidth: 48,
            arrow: false,
            center: true,
            padding: EdgeInsets.zero,
            label: const Text('9'),
            items: const [RappMenuItem(value: 1, label: '一')],
            onSelected: (_) {}),
      ])));
      final box = t.getRect(find.byKey(const Key('dd')));
      expect((t.getCenter(find.text('9')).dx - box.center.dx).abs() < 0.5, true);
    });
    testWidgets('textStyle gives the box and the rows a size, and open w600 still applies', (t) async {
      const small = TextStyle(fontSize: 11, fontWeight: FontWeight.w400);
      await t.pumpWidget(onP(TargetPlatform.macOS, RappDropdown<int>(
        key: const Key('dd'),
        textStyle: small,
        current: 1,
        label: const Text('甲'),
        items: const [RappMenuItem(value: 1, label: '一')],
        onSelected: (_) {},
      )));
      await t.tap(find.byKey(const Key('dd')));
      await t.pumpAndSettle();
      final box = t.renderObject<RenderParagraph>(find.text('甲')).text.style!;
      expect((box.fontSize, box.fontWeight), (11.0, FontWeight.w600));
      expect(t.renderObject<RenderParagraph>(find.text('一')).text.style!.fontSize, 11);
    });
  });

  group('RappMenuItem.caption', () {
    testWidgets('is a disabled row with no value', (t) async {
      await t.pumpWidget(onP(TargetPlatform.macOS, RappDropdown<int>(
        label: const Text('甲'),
        items: const [RappMenuItem<int>.caption(label: '说明'), RappMenuItem(value: 1, label: '一')],
        onSelected: (_) {},
      )));
      await t.tap(find.text('甲'));
      await t.pumpAndSettle();
      expect(t.widget<PopupMenuItem<int>>(find.widgetWithText(PopupMenuItem<int>, '说明')).enabled, false);
      expect(t.widget<PopupMenuItem<int>>(find.widgetWithText(PopupMenuItem<int>, '说明')).value, isNull);
    });
  });
  testWidgets('stage: a minimal square of the given size, the secondary button\'s corner and line', (t) async {
    await t.pumpWidget(wrap(RappButton.stage(key: const Key('r'), label: '输入', icon: Icons.keyboard_outlined, size: 56, onPressed: () {})));
    expect(t.getSize(find.byKey(const Key('r'))), const Size(56, 56));
    final tokens = RappTokens.of(t.element(find.byKey(const Key('r'))));
    final b = t.widget<OutlinedButton>(find.byType(OutlinedButton));
    final shape = b.style!.shape!.resolve({}) as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(tokens.r));
    expect(b.style!.side!.resolve({}), BorderSide(color: tokens.line));
    expect(b.style!.elevation!.resolve({}), 0);
    expect(find.bySemanticsLabel('输入'), findsOneWidget);
  });
}
