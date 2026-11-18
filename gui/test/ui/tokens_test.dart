import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/tokens.dart';

import 'platform_helpers.dart';

void main() {
  test('MATRIX token values match the design language table', () {
    final t = tokensFor(RappTheme.matrix);
    expect(t.bg, const Color(0xFF020A04));
    expect(t.panel, [const Color(0xFF041208)]);
    expect(t.line, const Color(0xFF176A33));
    expect(t.text, const Color(0xFF7DFF9E));
    expect(t.accent, const Color(0xFFF2FFF5));
    expect(t.accentInk, const Color(0xFF02240C));
    expect(t.tint, const Color.fromRGBO(125, 255, 158, .17));
    expect(t.r, 0);
    expect(t.monoBody, isTrue);
  });
  test('AVATAR panel and raise are vertical two-stop gradients', () {
    final t = tokensFor(RappTheme.avatar);
    expect(t.panel, [
      const Color.fromRGBO(255, 255, 255, .035),
      const Color.fromRGBO(255, 255, 255, .01),
    ]);
    expect(t.raise, [
      const Color.fromRGBO(150, 225, 255, .14),
      const Color.fromRGBO(150, 225, 255, .07),
    ]);
    expect(t.r, 4);
  });
  test('WESTWORLD values match the table', () {
    final w = tokensFor(RappTheme.westworld);
    expect(w.bg, const Color(0xFF070707));
    expect(w.text, const Color(0xFFF4F4F2));
    expect(w.accent, const Color(0xFFFF3B30));
    expect(w.r, 2);
  });
  test('every theme has an opaque bg, a lamp glow, and sane flags', () {
    for (final th in RappTheme.values) {
      final t = tokensFor(th);
      expect(t.bg.a, 1.0, reason: '$th');
      expect(t.glow, isNotEmpty, reason: '$th');
      expect(t.monoBody, th == RappTheme.matrix, reason: '$th');
      expect(
        t.textGlow.isNotEmpty,
        th == RappTheme.matrix,
        reason: '$th',
      );
      expect(
        t.labelSpacing,
        switch (th) {
          RappTheme.westworld => 0.12,
          _ => 0.06,
        },
        reason: '$th',
      );
    }
  });
  test('themeDataFor puts the text glow on every text style', () {
    for (final th in RappTheme.values) {
      final d = themeDataFor(th);
      final glow = tokensFor(th).textGlow;
      final tt = d.textTheme;
      for (final s in [
        tt.bodyMedium, tt.bodySmall, tt.bodyLarge, tt.labelLarge,
        tt.labelMedium, tt.titleMedium, tt.titleLarge,
      ]) {
        expect(s!.shadows ?? const <Shadow>[], glow, reason: '$th');
      }
    }
  });
  test('themeDataFor gives every text style the one text size', () {
    for (final th in RappTheme.values) {
      final d = themeDataFor(th, textSize: 13);
      expect(d.extension<RappTokens>()!.textSize, 13, reason: '$th');
      final tt = d.textTheme;
      for (final s in [
        tt.displayLarge, tt.headlineSmall, tt.titleLarge, tt.titleMedium, tt.titleSmall,
        tt.bodyLarge, tt.bodyMedium, tt.bodySmall, tt.labelLarge, tt.labelMedium, tt.labelSmall,
      ]) {
        expect(s!.fontSize, 13, reason: '$th');
        expect(s.height, 1.4, reason: '$th');
      }
      // Switch and checkbox rows come out 48 tall on touch (40 with the mouse density), like the dropdowns and buttons.
      expect(d.listTileTheme.minTileHeight, 48, reason: '$th');
    }
    expect(themeDataFor(RappTheme.matrix).textTheme.bodySmall!.fontSize, 15);
  });
  test('dropdown order and labels', () {
    expect(themeOrder.map(themeLabel), [
      'AVATAR',
      'MATRIX',
      'WESTWORLD',
    ]);
  });
  test('themeDataFor carries the tokens and 48px buttons', () {
    final d = themeDataFor(RappTheme.westworld);
    expect(d.extension<RappTokens>()!.accent, const Color(0xFFFF3B30));
    expect(d.filledButtonTheme.style!.minimumSize!.resolve({})!.height, 48);
    expect(d.textButtonTheme.style!.minimumSize!.resolve({})!.height, 48);
    expect(d.colorScheme.surface, const Color(0xFF070707));
  });
  test('panelBox uses a gradient for two stops and a solid for one', () {
    final a = tokensFor(RappTheme.avatar).panelBox();
    expect(a.gradient, isA<LinearGradient>());
    final m = tokensFor(RappTheme.matrix).panelBox();
    expect(m.color, const Color(0xFF041208));
    expect(m.gradient, isNull);
    expect(m.borderRadius, BorderRadius.circular(0));
  });
  test('what floats over the remote picture is opaque in every theme', () {
    for (final th in RappTheme.values) {
      final t = tokensFor(th);
      expect(t.float, isNotEmpty, reason: '$th');
      for (final c in t.float) {
        expect(c.a, 1.0, reason: '$th $c');
      }
      expect(t.copyWith(text: Colors.white).float, t.float, reason: '$th');
    }
    // AVATAR's glass panel stays see-through on its own backdrop.
    expect(tokensFor(RappTheme.avatar).panel.first.a, lessThan(1.0));
  });

  test('controlHeightFor: 48 on touch platforms, 40 with a mouse', () {
    for (final p in [TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.windows]) {
      expect(controlHeightFor(p), 40, reason: '$p');
      expect(touchPlatform(p), isFalse, reason: '$p');
    }
    for (final p in [TargetPlatform.iOS, TargetPlatform.android]) {
      expect(controlHeightFor(p), 48, reason: '$p');
      expect(touchPlatform(p), isTrue, reason: '$p');
    }
  });

  test('themeDataFor sets density, tap target and platform from the platform', () {
    final mac = themeDataFor(RappTheme.values.first, platform: TargetPlatform.macOS);
    expect(mac.visualDensity, VisualDensity.compact);
    expect(mac.materialTapTargetSize, MaterialTapTargetSize.shrinkWrap);
    expect(mac.platform, TargetPlatform.macOS);
    final ios = themeDataFor(RappTheme.values.first, platform: TargetPlatform.iOS);
    expect(ios.visualDensity, VisualDensity.standard);
    expect(ios.materialTapTargetSize, MaterialTapTargetSize.padded);
    expect(ios.platform, TargetPlatform.iOS);
  });

  for (final (p, h) in [(TargetPlatform.macOS, 40.0), (TargetPlatform.iOS, 48.0)]) {
    testWidgets('a FilledButton is $h tall on $p', (tester) async {
      await onPlatform(p, () async {
        await tester.pumpWidget(MaterialApp(
          theme: themeDataFor(RappTheme.values.first, platform: p),
          home: Scaffold(body: Center(child: FilledButton(onPressed: () {}, child: const Text('x')))),
        ));
        expect(tester.getSize(find.byType(FilledButton)).height, h);
      });
    });
  }

  test('control sub-themes carry the token colours', () {
    for (final theme in RappTheme.values) {
      final t = tokensFor(theme);
      final d = themeDataFor(theme, platform: TargetPlatform.macOS);
      const sel = {WidgetState.selected};
      expect(d.switchTheme.trackColor!.resolve(sel), t.accent);
      expect(d.checkboxTheme.fillColor!.resolve(sel), t.accent);
      final box = d.checkboxTheme.shape! as RoundedRectangleBorder;
      expect(box.borderRadius, BorderRadius.circular(t.r / 2));
      expect(d.popupMenuTheme.color, t.bg);
      final pop = d.popupMenuTheme.shape! as RoundedRectangleBorder;
      expect(pop.side.color, t.text);
      expect(pop.borderRadius, BorderRadius.circular(t.r));
      final i = d.inputDecorationTheme;
      expect(i.isDense, isTrue);
      expect(i.floatingLabelBehavior, FloatingLabelBehavior.always);
      final en = i.enabledBorder! as OutlineInputBorder;
      expect(en.borderSide.color, t.line);
      expect(en.borderRadius, BorderRadius.circular(t.r));
      expect((i.focusedBorder! as OutlineInputBorder).borderSide.color, t.text);
      expect(d.sliderTheme.activeTrackColor, t.accent);
      expect(d.sliderTheme.inactiveTrackColor, t.line);
      expect(d.sliderTheme.trackHeight, 3);
    }
  });
}
