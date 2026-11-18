import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/tab_chip.dart';

import 'helpers.dart';
import 'platform_helpers.dart';

void main() {
  for (final (p, min) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
    testWidgets('a tab chip × is at least $min square on $p, and works at its edge', (tester) async {
      await onPlatform(p, () async {
        var closed = 0;
        await tester.pumpWidget(wrap(TabChip(label: 'A', selected: false, onTap: () {}, onClose: () => closed++)));
        final close = find.byKey(const Key('tab-close'));
        final s = tester.getSize(close);
        expect(s.width, greaterThanOrEqualTo(min));
        expect(s.height, greaterThanOrEqualTo(min));
        await tester.tapAt(tester.getTopLeft(close) + const Offset(1, 1));
        expect(closed, 1);
      });
    });
  }

  testWidgets('a tab chip without onTap is announced as disabled', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(wrap(const TabChip(key: Key('c'), label: 'A', selected: false, onTap: null)));
    expect(tester.getSemantics(find.byKey(const Key('c'))).getSemanticsData().flagsCollection.isEnabled, Tristate.isFalse);
    await tester.pumpWidget(wrap(TabChip(key: const Key('c'), label: 'A', selected: false, onTap: () {})));
    expect(tester.getSemantics(find.byKey(const Key('c'))).getSemanticsData().flagsCollection.isEnabled, Tristate.isTrue);
    h.dispose();
  });
}
