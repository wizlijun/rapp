import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/net_marker.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';

void main() {
  test('each level has its own mark: cheetah, rabbit, tortoise, cracked egg', () {
    final assets = NetLevel.values.map(netAsset).toList();
    expect(assets, [
      'assets/net/strong.png',
      'assets/net/ok.png',
      'assets/net/weak.png',
      'assets/net/down.png',
    ]);
    expect(assets.toSet(), hasLength(NetLevel.values.length));
  });

  testWidgets('every level is in the asset bundle at 1x, 2x and 3x', (tester) async {
    for (final l in NetLevel.values) {
      for (final name in [netAsset(l), netAsset(l).replaceFirst('net/', 'net/2.0x/'), netAsset(l).replaceFirst('net/', 'net/3.0x/')]) {
        final data = await rootBundle.load(name);
        expect(data.lengthInBytes, greaterThan(0), reason: name);
      }
    }
  });

  testWidgets('colours: strong on, ok text, weak accent, down error', (tester) async {
    late RappTokens t;
    late ColorScheme cs;
    await tester.pumpWidget(wrap(Builder(builder: (context) {
      t = RappTokens.of(context);
      cs = Theme.of(context).colorScheme;
      return const SizedBox();
    })));
    expect(netColor(NetLevel.strong, t, cs), t.on);
    expect(netColor(NetLevel.ok, t, cs), t.text);
    expect(netColor(NetLevel.weak, t, cs), t.accent);
    expect(netColor(NetLevel.down, t, cs), cs.error);
  });

  test('words and tooltip', () {
    expect(NetLevel.values.map(netWord), ['强', '一般', '弱', '断开']);
    const ok = NetStatus(NetLevel.ok, 160, 0.03);
    expect(netTooltip(ok), '本机网络 · 一般 · 中继 160ms · 丢包 3%');
    expect(netTooltip(ok, path: 'relay'), '本机网络 · 一般 · 中继 160ms · 丢包 3%');
    expect(netTooltip(ok, path: 'lan'), '本机网络 · 一般 · 中继 160ms · 丢包 3%\n当前会话走局域网，不经过中继');
    expect(netTooltip(const NetStatus(NetLevel.down, 160, 1)), '本机网络 · 断开');
    expect(netTooltip(const NetStatus(NetLevel.strong, null, 0)), '本机网络 · 强 · 丢包 0%');
  });

  testWidgets('the mark alone, no round trip; the words are its hover', (tester) async {
    const n = NetStatus(NetLevel.strong, 42, 0);
    await tester.pumpWidget(wrap(const NetMarker(net: n)));
    expect(find.byKey(const Key('net-mark')), findsOneWidget);
    expect(find.text('42ms'), findsNothing);
    expect(tester.getSize(find.byKey(const Key('net-marker'))).width, NetMarker.width);
    expect(tester.getSemantics(find.byKey(const Key('net-marker'))).label, netTooltip(n));
    expect(find.byTooltip(netTooltip(n)), findsOneWidget);
  });

  testWidgets('the mark keeps its whole 28×14 canvas and is tinted as a template', (tester) async {
    late RappTokens t;
    late ColorScheme cs;
    for (final l in NetLevel.values) {
      await tester.pumpWidget(wrap(Builder(builder: (context) {
        t = RappTokens.of(context);
        cs = Theme.of(context).colorScheme;
        return NetMarker(net: NetStatus(l, 500, 0.2));
      })));
      expect(tester.takeException(), isNull, reason: '$l');
      final img = tester.widget<Image>(find.byKey(const Key('net-mark')));
      expect((img.image as AssetImage).assetName, netAsset(l), reason: '$l');
      expect(img.color, netColor(l, t, cs), reason: '$l');
      expect(img.colorBlendMode ?? BlendMode.srcIn, BlendMode.srcIn, reason: '$l');
      // No crop, no stretch: the canvas is the art's own size, drawn whole.
      expect(img.fit, isNull, reason: '$l');
      expect(tester.getSize(find.byKey(const Key('net-mark'))), const Size(28, 14), reason: '$l');
    }
  });
}
