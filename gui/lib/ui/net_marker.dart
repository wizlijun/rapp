// The top bar's network marker (spec 2026-11-14-rapp-network-status §4.1): the level's mark, left
// of the traffic label. A macOS-style wifi fan of three segments — a wedge and two bands — lit from
// the bottom: strong lights all three, ok two, weak one, down none. Unlit segments are the same
// colour at [netDimAlpha], so the count of lit ones tells the levels apart without colour.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'session_model.dart';

/// A round trip at or above this is weak (§3.4); a segment of the path is judged by it too.
const weakRttMs = 300;

String netWord(NetLevel l) => switch (l) {
      NetLevel.strong => '强',
      NetLevel.ok => '一般',
      NetLevel.weak => '弱',
      NetLevel.down => '断开',
    };

/// How many of the fan's three segments the level lights, from the bottom.
int netBars(NetLevel l) => switch (l) {
      NetLevel.strong => 3,
      NetLevel.ok => 2,
      NetLevel.weak => 1,
      NetLevel.down => 0,
    };

/// The opacity of an unlit segment, relative to the lit colour.
const netDimAlpha = 0.3;

/// `本机网络 · 一般 · 中继 160ms · 丢包 3%`, and a second line when the current session's [path]
/// is `lan` or `direct` (it does not go through the relay).
String netTooltip(NetStatus n, {String? path}) {
  final parts = ['本机网络', netWord(n.level)];
  if (n.level != NetLevel.down) {
    if (n.rttMs != null) parts.add('中继 ${n.rttMs}ms');
    parts.add('丢包 ${(n.loss * 100).round()}%');
  }
  final off = path == 'lan' || path == 'direct';
  return parts.join(' · ') + (off ? '\n当前会话走${routeWord(path)}，不经过中继' : '');
}

/// The mark alone; the words (the tooltip's) are in its hover and atop the traffic menu.
class NetMarker extends StatelessWidget {
  const NetMarker({super.key, required this.net, this.path});

  final NetStatus net;

  /// The current session's path, for the tooltip.
  final String? path;

  /// The mark's canvas, the same for all four levels.
  static const markSize = Size(18, 18);

  /// Width the marker takes in the top bar: the mark and 6 either side.
  static const width = 30.0;

  @override
  Widget build(BuildContext context) {
    final tip = netTooltip(net, path: path);
    return Tooltip(
      message: tip,
      child: Semantics(
        key: const Key('net-marker'),
        label: tip,
        excludeSemantics: true,
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          child: CustomPaint(
            key: const Key('net-mark'),
            size: markSize,
            painter: WifiMarkPainter(
              bars: netBars(net.level),
              color: IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// The fan, drawn on a 24×24 grid scaled to the canvas: a wedge and two bands about one centre,
/// ±45°. Bands and the gaps between them look equally wide (2.6 units) once the rounding stroke
/// is added, so the shapes are drawn 0.4 short of that on each side.
class WifiMarkPainter extends CustomPainter {
  const WifiMarkPainter({required this.bars, required this.color});

  /// Lit segments, 0–3, from the bottom.
  final int bars;
  final Color color;

  static const _cx = 12.0, _cy = 19.4, _round = 0.8;

  /// Each segment's inner and outer radius on the grid; the wedge starts at the centre.
  static const segments = [(0.0, 4.0), (7.4, 9.2), (12.6, 14.4)];

  static Offset _at(double r, double side) =>
      Offset(_cx + side * r * math.sin(math.pi / 4), _cy - r * math.cos(math.pi / 4));

  static Path segment(double inner, double outer) {
    final p = Path();
    final o = Radius.circular(outer);
    if (inner == 0) {
      p.moveTo(_cx, _cy);
    } else {
      p.moveTo(_at(inner, 1).dx, _at(inner, 1).dy);
      p.arcToPoint(_at(inner, -1), radius: Radius.circular(inner), clockwise: false);
    }
    p.lineTo(_at(outer, -1).dx, _at(outer, -1).dy);
    p.arcToPoint(_at(outer, 1), radius: o);
    return p..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = math.min(size.width, size.height) / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final fill = Paint()..isAntiAlias = true;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _round
      ..strokeJoin = StrokeJoin.round;
    for (var i = 0; i < segments.length; i++) {
      final (inner, outer) = segments[i];
      final path = segment(inner, outer);
      final lit = i < bars;
      // An unlit segment goes through a layer, so its fill and the rounding stroke over it blend
      // once, not twice where they overlap.
      if (!lit) canvas.saveLayer(path.getBounds().inflate(1), Paint()..color = Color.fromRGBO(0, 0, 0, netDimAlpha));
      canvas.drawPath(path, fill..color = color);
      canvas.drawPath(path, edge..color = color);
      if (!lit) canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(WifiMarkPainter old) => old.bars != bars || old.color != color;
}
