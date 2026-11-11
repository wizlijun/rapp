import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';

Finder _spin() => find.descendant(
  of: find.byType(StatusLamp),
  matching: find.byType(RotationTransition),
);

void main() {
  test('seven lamps are pairwise distinct by shape+stroke alone', () {
    final specs = Lamp.values.map((l) {
      final s = lampSpec(l);
      return (s.shape, s.stroke);
    }).toSet();
    expect(specs.length, 7);
  });
  test('only waiting blinks, only connecting spins', () {
    expect(Lamp.values.where((l) => lampSpec(l).blinks), [Lamp.waiting]);
    expect(Lamp.values.where((l) => lampSpec(l).spins), [Lamp.connecting]);
  });
  test('words come from the vocabulary', () {
    expect(Lamp.values.map(lampWord), [
      '活动',
      '空闲',
      '连接中',
      '已断开',
      '等你',
      '离线',
      '未打开',
    ]);
  });
  test('row backdrops and borders', () {
    final t = tokensFor(RappTheme.matrix);
    expect(rowBackdrop(Lamp.active, t), isNull);
    expect(rowBackdrop(Lamp.disconnected, t), isNotNull);
    expect(rowBackdrop(Lamp.offline, t), isNotNull);
    expect((rowBackdrop(Lamp.waiting, t) as BoxDecoration).color, t.tint);
    expect(rowBorder(Lamp.waiting, t), t.accent);
    expect(rowBorder(Lamp.disconnected, t, selected: true), t.accent);
    expect(rowBorder(Lamp.active, t, selected: true), t.text);
    expect(rowBorder(Lamp.active, t), t.line);
  });
  testWidgets('reduced motion builds no animation', (t) async {
    await t.pumpWidget(
      wrap(const StatusLamp(Lamp.connecting), disableAnimations: true),
    );
    expect(_spin(), findsNothing);
  });
  testWidgets('connecting spins when motion allowed', (t) async {
    await t.pumpWidget(wrap(const StatusLamp(Lamp.connecting)));
    expect(_spin(), findsOneWidget);
  });
  testWidgets('waiting blinks hard on/off', (t) async {
    await t.pumpWidget(wrap(const StatusLamp(Lamp.waiting)));
    double op() => t
        .widget<FadeTransition>(
          find.descendant(
            of: find.byType(StatusLamp),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;
    expect(op(), 1);
    await t.pump(const Duration(milliseconds: 600));
    expect(op(), 0);
  });
  testWidgets('every lamp paints', (t) async {
    await t.pumpWidget(
      wrap(Column(children: [for (final l in Lamp.values) StatusLamp(l)])),
    );
    expect(find.byType(StatusLamp), findsNWidgets(7));
  });
}
