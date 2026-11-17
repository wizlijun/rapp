import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/net_marker.dart';

import 'helpers.dart';

void main() {
  test('each level lights its own count of the fan, from the bottom', () {
    expect(NetLevel.values.map(netBars), [3, 2, 1, 0]);
  });

  test('bands and gaps look equally wide once the rounding stroke is on', () {
    const round = 0.8;
    final segs = WifiMarkPainter.segments;
    // Seen widths: each shape grows by half the stroke on each side.
    final bands = [for (final (a, b) in segs.skip(1)) (b - a) + round];
    final gaps = [for (var i = 1; i < segs.length; i++) (segs[i].$1 - segs[i - 1].$2) - round];
    for (final w in [...bands, ...gaps]) {
      expect(w, closeTo(2.6, 1e-9));
    }
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

  testWidgets('the fan fills its 14×14 canvas in the icon colour, lit by level', (tester) async {
    for (final l in NetLevel.values) {
      await tester.pumpWidget(wrap(IconTheme(
        data: const IconThemeData(color: Color(0xFF7DFF9E)),
        child: NetMarker(net: NetStatus(l, 500, 0.2)),
      )));
      expect(tester.takeException(), isNull, reason: '$l');
      final paint = tester.widget<CustomPaint>(find.byKey(const Key('net-mark')));
      final p = paint.painter! as WifiMarkPainter;
      expect(p.bars, netBars(l), reason: '$l');
      expect(p.color, const Color(0xFF7DFF9E), reason: '$l');
      expect(tester.getSize(find.byKey(const Key('net-mark'))), const Size(14, 14), reason: '$l');
    }
  });

  test('the fan stays inside its 24-unit grid', () {
    // The outer band is the widest and tallest: its ends at ±45° and its apex; the centre is lowest.
    final r = WifiMarkPainter.segments.last.$2 + 0.4;
    final half = r * math.sin(math.pi / 4);
    expect(12 - half, greaterThanOrEqualTo(0));
    expect(12 + half, lessThanOrEqualTo(24));
    expect(19.4 - r, greaterThanOrEqualTo(0));
    expect(19.4 + 0.4, lessThanOrEqualTo(24));
  });
}
