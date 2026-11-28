// 快捷区的键面字体 (key-glyphs): each platform's own UI font, so ⏎ ⌫ ↑ look like the keys on a real keyboard.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/key_bar_keys.dart';
import 'package:rapp/embed/key_glyph.dart';

import '../ui/helpers.dart';

void main() {
  test('a key face is a lone symbol when it is one character and not a letter or digit', () {
    for (final s in ['⌫', '⏎', '↑', '↓', '←', '→', '⌘', '⌃', '⋯']) {
      expect(isSymbolKeyLabel(s), isTrue, reason: s);
    }
    for (final s in ['Tab', '⇧Tab', 'Esc', '⌃C', '⌘T', 'PgUp', 'A', '1', '']) {
      expect(isSymbolKeyLabel(s), isFalse, reason: s);
    }
  });

  test('each platform gets its own UI font, with fallbacks for the key symbols; never the mono font', () {
    final apple = keyFaceStyle(TargetPlatform.iOS, 'Tab');
    expect(apple.fontFamily, 'CupertinoSystemText'); // SF Pro on iOS and macOS
    expect(keyFaceStyle(TargetPlatform.macOS, 'Tab').fontFamily, 'CupertinoSystemText');
    final win = keyFaceStyle(TargetPlatform.windows, '⌫');
    expect(win.fontFamily, 'Segoe UI');
    expect(win.fontFamilyFallback, contains('Segoe UI Symbol'));
    final android = keyFaceStyle(TargetPlatform.android, '⌫');
    expect(android.fontFamily, 'Roboto');
    expect(android.fontFamilyFallback, containsAll(['Noto Sans Symbols', 'Noto Sans Symbols 2']));
    final linux = keyFaceStyle(TargetPlatform.linux, '⌫');
    expect(linux.fontFamily, 'sans-serif');
    expect(linux.fontFamilyFallback, containsAll(['DejaVu Sans', 'Noto Sans Symbols 2']));
    for (final p in TargetPlatform.values) {
      final st = keyFaceStyle(p, '⏎');
      expect(st.fontFamily, isNot(contains('Mono')), reason: '$p');
      expect(st.fontFamilyFallback ?? const [], isNot(contains('Menlo')), reason: '$p');
    }
  });

  test('a lone symbol is drawn bigger than a word, both medium weight', () {
    for (final p in TargetPlatform.values) {
      expect(keyFaceStyle(p, '⏎').fontSize, 19, reason: '$p');
      expect(keyFaceStyle(p, 'PgUp').fontSize, 14, reason: '$p');
      expect(keyFaceStyle(p, '⏎').fontWeight, FontWeight.w500);
      expect(keyFaceStyle(p, 'PgUp').fontWeight, FontWeight.w500);
    }
  });

  Future<TextStyle> faceStyle(WidgetTester tester, TargetPlatform p, String label, {double width = 60}) async {
    await tester.pumpWidget(wrap(Builder(
      builder: (context) => Theme(
        data: Theme.of(context).copyWith(platform: p),
        child: SizedBox(width: width, height: keyBarKeyHeight, child: KeyFace(label: label)),
      ),
    )));
    return tester.widget<Text>(find.text(label)).style!;
  }

  testWidgets('KeyFace draws with the platform\'s key style', (tester) async {
    final ios = await faceStyle(tester, TargetPlatform.iOS, '⌫');
    expect(ios.fontFamily, 'CupertinoSystemText');
    expect(ios.fontSize, 19);
    final win = await faceStyle(tester, TargetPlatform.windows, 'Esc');
    expect(win.fontFamily, 'Segoe UI');
    expect(win.fontSize, 14);
  });

  testWidgets('a word too wide for a narrow key shrinks instead of being cut off', (tester) async {
    await faceStyle(tester, TargetPlatform.iOS, 'PgUp', width: 24);
    expect(tester.takeException(), isNull);
    expect(find.descendant(of: find.byType(KeyFace), matching: find.byType(FittedBox)), findsOneWidget);
    expect(tester.widget<Text>(find.text('PgUp')).overflow, isNot(TextOverflow.ellipsis));
  });

  test('return and the four arrows are drawn glyphs; every other face stays text', () {
    expect(keyGlyphOf('⏎'), KeyGlyph.enter);
    expect(keyGlyphOf('↑'), KeyGlyph.up);
    expect(keyGlyphOf('↓'), KeyGlyph.down);
    expect(keyGlyphOf('←'), KeyGlyph.left);
    expect(keyGlyphOf('→'), KeyGlyph.right);
    for (final s in ['⌫', '⌘', '⋯', 'Tab', 'PgUp', '⌃C']) {
      expect(keyGlyphOf(s), isNull, reason: s);
    }
  });

  testWidgets('⏎ and the arrows draw the thick-line glyph instead of a font symbol, and still read as the key',
      (tester) async {
    for (final (label, g) in [('⏎', KeyGlyph.enter), ('↑', KeyGlyph.up), ('→', KeyGlyph.right)]) {
      await tester.pumpWidget(wrap(SizedBox(width: 60, height: keyBarKeyHeight, child: KeyFace(label: label))));
      expect(find.text(label), findsNothing, reason: label);
      final icon = tester.widget<KeyGlyphIcon>(find.byType(KeyGlyphIcon));
      expect(icon.glyph, g);
      expect(icon.size, keyGlyphSize);
      expect(find.bySemanticsLabel(label), findsOneWidget);
    }
    expect(keyGlyphStroke, 2.8);
    expect(keyGlyphSize, 23);
  });

  test('the lone control key reads Ctrl; the ⌃C-style chords keep their symbol', () {
    expect(barKeys['ctrl']!.label, 'Ctrl');
    expect(barKeys['cc']!.label, '⌃C');
  });
}
