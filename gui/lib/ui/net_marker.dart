// The top bar's network marker (spec 2026-11-14-rapp-network-status §4.1): a pulse line and the
// round trip to the relay, left of the traffic label. Shape and colour both tell the four levels
// apart, so the shape alone does for colour-blind eyes; nothing about it looks like a wifi fan.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'session_model.dart';
import 'tokens.dart';

/// A round trip at or above this is weak (§3.4); a segment of the path is judged by it too.
const weakRttMs = 300;

String netWord(NetLevel l) => switch (l) {
      NetLevel.strong => '强',
      NetLevel.ok => '一般',
      NetLevel.weak => '弱',
      NetLevel.down => '断开',
    };

/// The line in a 1×1 box (x right, y down, 0.5 the baseline): strong one small beat, ok a
/// taller up-and-down beat, weak jagged all along, down a dashed flat line crossed out.
typedef NetLine = ({List<Offset> points, bool dashed, bool crossed});

NetLine netLine(NetLevel l) => switch (l) {
      NetLevel.strong => (
          points: const [Offset(0, .5), Offset(.4, .5), Offset(.5, .25), Offset(.6, .5), Offset(1, .5)],
          dashed: false,
          crossed: false,
        ),
      NetLevel.ok => (
          points: const [Offset(0, .5), Offset(.25, .5), Offset(.35, .15), Offset(.5, .85), Offset(.6, .5), Offset(1, .5)],
          dashed: false,
          crossed: false,
        ),
      NetLevel.weak => (
          points: const [
            Offset(0, .5), Offset(.1, .1), Offset(.22, .9), Offset(.34, .1), Offset(.46, .9), //
            Offset(.58, .1), Offset(.7, .9), Offset(.82, .1), Offset(.94, .9), Offset(1, .5),
          ],
          dashed: false,
          crossed: false,
        ),
      NetLevel.down => (points: const [Offset(0, .5), Offset(1, .5)], dashed: true, crossed: true),
    };

/// Strong in the lamps' on colour, ok in the text colour, weak in the warning colour (the accent, as the
/// lamps use it), down in the theme's error colour.
Color netColor(NetLevel l, RappTokens t, ColorScheme cs) => switch (l) {
      NetLevel.strong => t.on,
      NetLevel.ok => t.text,
      NetLevel.weak => t.accent,
      NetLevel.down => cs.error,
    };

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

/// The words beside the line: the round trip, 断开, or none while no round trip is known.
String? netText(NetStatus n) => n.level == NetLevel.down ? '断开' : (n.rttMs == null ? null : '${n.rttMs}ms');

class NetMarker extends StatelessWidget {
  const NetMarker({super.key, required this.net, this.compact = false, this.path});

  final NetStatus net;

  /// The line alone, no words (narrow top bar).
  final bool compact;

  /// The current session's path, for the tooltip.
  final String? path;

  static const lineSize = Size(28, 14);

  /// Width the marker takes in the top bar, with words and without.
  static const wideWidth = 96.0;
  static const compactWidth = 40.0;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final color = netColor(net.level, t, Theme.of(context).colorScheme);
    final text = compact ? null : netText(net);
    final tip = netTooltip(net, path: path);
    return Tooltip(
      message: tip,
      child: Semantics(
        key: const Key('net-marker'),
        label: tip,
        excludeSemantics: true,
        child: Container(
          width: compact ? compactWidth : wideWidth,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                key: const Key('net-line'),
                size: lineSize,
                painter: NetLinePainter(netLine(net.level), color),
              ),
              if (text != null) ...[
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                  text,
                  key: const Key('net-text'),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(fontFamily: t.mono, fontFamilyFallback: t.monoFallback, fontSize: 12, color: color),
                ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class NetLinePainter extends CustomPainter {
  NetLinePainter(this.line, this.color);

  final NetLine line;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    Offset at(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    final pts = line.points.map(at).toList();
    if (line.dashed) {
      for (var i = 0; i + 1 < pts.length; i++) {
        _dash(canvas, pts[i], pts[i + 1], paint);
      }
    } else {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
    if (line.crossed) {
      final c = size.center(Offset.zero);
      final r = size.height * .3;
      final cross = Paint()
        ..color = color
        ..strokeWidth = 1.8;
      // A clear gap under the ✕ so it reads apart from the dashes.
      canvas.drawRect(Rect.fromCircle(center: c, radius: r + 1.5), Paint()..blendMode = BlendMode.clear);
      canvas.drawLine(c + Offset(-r, -r), c + Offset(r, r), cross);
      canvas.drawLine(c + Offset(-r, r), c + Offset(r, -r), cross);
    }
  }

  void _dash(Canvas canvas, Offset a, Offset b, Paint paint) {
    const on = 3.0, off = 2.5;
    final len = (b - a).distance;
    final dir = (b - a) / math.max(len, 1e-6);
    for (var d = 0.0; d < len; d += on + off) {
      canvas.drawLine(a + dir * d, a + dir * math.min(d + on, len), paint);
    }
  }

  @override
  bool shouldRepaint(NetLinePainter old) => old.line != line || old.color != color;
}
