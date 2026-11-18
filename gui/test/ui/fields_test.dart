import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/tokens.dart';

import 'platform_helpers.dart';

void main() {
  for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
    testWidgets('plain TextField is $h tall with a line outline on $p', (t) async {
      await onPlatform(p, () async {
        await t.pumpWidget(MaterialApp(
          theme: themeDataFor(RappTheme.matrix, platform: p),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 300, child: TextField(decoration: InputDecoration(labelText: '名字'))),
            ),
          ),
        ));
        expect(t.getSize(find.byType(InputDecorator)).height, h);
        final theme = Theme.of(t.element(find.byType(TextField)));
        final b = theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
        expect(b.borderSide.color, tokensFor(RappTheme.matrix).line);
      });
    });
  }
  testWidgets('errorText takes the colour scheme error colour', (t) async {
    final th = themeDataFor(RappTheme.matrix, platform: TargetPlatform.macOS);
    await t.pumpWidget(MaterialApp(
      theme: th,
      home: const Scaffold(body: TextField(decoration: InputDecoration(labelText: '名字', errorText: '不对'))),
    ));
    expect(t.widget<Text>(find.text('不对')).style!.color, th.colorScheme.error);
  });
}
