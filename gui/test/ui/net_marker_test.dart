import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/net_marker.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';

void main() {
  test('the four levels draw four different lines; only down is dashed and crossed', () {
    final lines = NetLevel.values.map(netLine).toList();
    for (var i = 0; i < lines.length; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        expect(lines[i].points, isNot(equals(lines[j].points)), reason: '${NetLevel.values[i]} vs ${NetLevel.values[j]}');
      }
    }
    for (final l in NetLevel.values) {
      final line = netLine(l);
      expect(line.dashed, l == NetLevel.down, reason: '$l');
      expect(line.crossed, l == NetLevel.down, reason: '$l');
      for (final p in line.points) {
        expect(p.dx, inInclusiveRange(0, 1));
        expect(p.dy, inInclusiveRange(0, 1));
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

  testWidgets('the line alone, no round trip; the words are its hover', (tester) async {
    const n = NetStatus(NetLevel.strong, 42, 0);
    await tester.pumpWidget(wrap(const NetMarker(net: n)));
    expect(find.byKey(const Key('net-line')), findsOneWidget);
    expect(find.text('42ms'), findsNothing);
    expect(tester.getSize(find.byKey(const Key('net-marker'))).width, NetMarker.width);
    expect(tester.getSemantics(find.byKey(const Key('net-marker'))).label, netTooltip(n));
    expect(find.byTooltip(netTooltip(n)), findsOneWidget);
  });

  testWidgets('every level paints without error', (tester) async {
    for (final l in NetLevel.values) {
      await tester.pumpWidget(wrap(NetMarker(net: NetStatus(l, 500, 0.2))));
      expect(tester.takeException(), isNull);
    }
  });

  test('the gap under the cross is cleared inside its own layer, never through the bar', () {
    for (final l in NetLevel.values) {
      final c = _RecordingCanvas();
      NetLinePainter(netLine(l), const Color(0xff00ff00)).paint(c, const Size(24, 14));
      expect(c.clearOutsideLayer, isFalse, reason: '$l');
      expect(c.depth, 0, reason: '$l: every saveLayer restored');
    }
  });
}

class _RecordingCanvas implements Canvas {
  int depth = 0;
  bool clearOutsideLayer = false;

  void _check(Paint p) {
    if (p.blendMode == ui.BlendMode.clear && depth == 0) clearOutsideLayer = true;
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) => depth++;
  @override
  void restore() => depth--;
  @override
  void drawRect(Rect rect, Paint paint) => _check(paint);
  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => _check(paint);
  @override
  void drawPath(Path path, Paint paint) => _check(paint);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
