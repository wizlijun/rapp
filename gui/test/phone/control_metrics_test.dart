import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/tokens.dart';

/// R30: the shared controls keep today's 48 high and 8 apart; only a page that says so (the phone settings) asks for more.
void main() {
  Future<void> pump(WidgetTester tester, {ControlMetrics Function(Widget)? wrap}) async {
    Widget body = Builder(builder: (c) => Column(children: [
          RappSwitchRow(label: 'x', value: true, onChanged: (_) {}),
          RappButton.secondary(label: 'b', onPressed: () {}),
          SizedBox(key: const Key('gap'), height: controlGapOf(c)),
        ]));
    if (wrap != null) body = wrap(body);
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix, platform: TargetPlatform.iOS), home: Scaffold(body: body)));
  }

  testWidgets('default is 48 high, 8 apart', (tester) async {
    await pump(tester);
    expect(tester.getSize(find.byType(RappSwitchRow)).height, 48);
    expect(tester.getSize(find.byType(RappButton)).height, 48);
    expect(tester.getSize(find.byKey(const Key('gap'))).height, 8);
  });

  testWidgets('ControlMetrics asks for 56 and 12', (tester) async {
    await pump(tester, wrap: (c) => ControlMetrics(minHeight: 56, gap: 12, child: c));
    expect(tester.getSize(find.byType(RappSwitchRow)).height, 56);
    expect(tester.getSize(find.byType(RappButton)).height, 56);
    expect(tester.getSize(find.byKey(const Key('gap'))).height, 12);
  });
}
