import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/overview.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';

void main() {
  test('every theme names an overview image that exists and is bundled', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('- $themeAssetDir/'));
    for (final th in RappTheme.values) {
      final t = tokensFor(th);
      expect(t.overviewArt, 'overview_${th.name}.png', reason: '$th');
      expect(t.overviewArtAsset, '$themeAssetDir/overview_${th.name}.png', reason: '$th');
      expect(File(t.overviewArtAsset!).existsSync(), isTrue, reason: '$th');
    }
  });

  test('copyWith keeps the image unless one is given', () {
    final t = tokensFor(RappTheme.avatar);
    expect(t.copyWith(text: Colors.white).overviewArt, 'overview_avatar.png');
    expect(t.copyWith(overviewArt: 'x.png').overviewArtAsset, '$themeAssetDir/x.png');
  });

  Future<void> show(WidgetTester tester, Size box, {RappTheme theme = RappTheme.matrix}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(wrap(SizedBox(width: box.width, height: box.height, child: const OverviewArt()), theme: theme));
    await tester.pump(const Duration(seconds: 1)); // MaterialApp animates a theme change
  }

  final art = find.byKey(const Key('overview-art'));

  testWidgets('each theme shows its own image', (tester) async {
    for (final th in RappTheme.values) {
      await show(tester, const Size(1194, 700), theme: th);
      final img = tester.widget<Image>(art);
      final provider = (img.image as ResizeImage).imageProvider as AssetImage;
      expect(provider.assetName, '$themeAssetDir/overview_${th.name}.png', reason: '$th');
      expect(img.fit, BoxFit.contain);
    }
  });

  testWidgets('bottom-right, above the project row, 440 at most', (tester) async {
    await show(tester, const Size(1194, 700));
    final box = tester.getRect(find.byType(OverviewArt));
    final r = tester.getRect(art);
    expect(r.width, overviewArtMaxSide);
    expect(r.height, overviewArtMaxSide);
    expect(r.right, box.right - 12);
    expect(r.bottom, box.bottom - 112);
  });

  testWidgets('shrinks with the room it has, and goes away when there is none', (tester) async {
    await show(tester, const Size(600, 400));
    expect(tester.getSize(art).width, 400 - 2 * 112);
    await show(tester, const Size(500, 900));
    expect(tester.getSize(art).width, 500 * .45);
    await show(tester, const Size(1194, 260));
    expect(art, findsNothing);
  });

  testWidgets('decoration only: no pointer, no semantics', (tester) async {
    await show(tester, const Size(1194, 700));
    final ignore = tester.widget<IgnorePointer>(find.ancestor(of: art, matching: find.byType(IgnorePointer)).first);
    expect(ignore.ignoring, isTrue);
    expect(find.ancestor(of: art, matching: find.byType(ExcludeSemantics)), findsWidgets);
  });

  testWidgets('a missing file paints nothing and throws nothing', (tester) async {
    final tokens = tokensFor(RappTheme.matrix).copyWith(overviewArt: 'missing.png');
    await tester.pumpWidget(MaterialApp(
      theme: themeDataFor(RappTheme.matrix).copyWith(extensions: [tokens]),
      home: const Scaffold(body: SizedBox(width: 1194, height: 700, child: OverviewArt())),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
