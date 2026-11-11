import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/controls.dart';

import 'helpers.dart';

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
}
