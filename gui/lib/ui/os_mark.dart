// The system mark beside a device's lamp on the overview (全景): one colour, drawn with paths, the lamp's size.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'device_os.dart';
import 'tokens.dart';

/// What system a device is, as a small mark the size of a [StatusLamp]. The word shows on hover and is what
/// screen readers say.
class OsMark extends StatelessWidget {
  const OsMark(this.os, {super.key, this.size = 10});
  final DeviceOs os;
  final double size;

  @override
  Widget build(BuildContext context) {
    final word = osWord(os);
    return Tooltip(
      message: word,
      child: Semantics(
        label: word,
        excludeSemantics: true,
        child: CustomPaint(
          key: const Key('os-mark-paint'),
          size: Size.square(size * 1.3),
          painter: OsMarkPainter(os, RappTokens.of(context).muted, size),
        ),
      ),
    );
  }
}

/// Draws on a 24-unit grid scaled to the box (`size * 1.3`); outlines keep the lamp's `1.6 * size / 10` line.
class OsMarkPainter extends CustomPainter {
  OsMarkPainter(this.os, this.color, this.size);
  final DeviceOs os;
  final Color color;
  final double size;

  @override
  void paint(Canvas canvas, Size box) {
    final u = box.shortestSide / 24;
    final line = 1.6 * size / 10 / u;
    canvas.save();
    canvas.translate((box.width - 24 * u) / 2, (box.height - 24 * u) / 2);
    canvas.scale(u);
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = line;
    switch (os) {
      case DeviceOs.macos:
        canvas.drawPath(_apple(), fill);
      case DeviceOs.windows:
        canvas.drawPath(_panes(), fill);
      case DeviceOs.omarchy:
        canvas.drawPath(_omarchy(), stroke);
      case DeviceOs.linux:
        canvas.drawPath(_penguin(), fill);
      case DeviceOs.ipad || DeviceOs.androidTablet:
        canvas.drawPath(_device(const Rect.fromLTWH(3, 1, 18, 22), 3, .62, os == DeviceOs.ipad ? _apple() : _robot()), fill);
      case DeviceOs.iphone || DeviceOs.androidPhone:
        canvas.drawPath(_device(const Rect.fromLTWH(6, 0.5, 12, 23), 3.2, .7, os == DeviceOs.iphone ? _apple() : _robot()), fill);
      case DeviceOs.unknown:
        _unknown(canvas, fill, stroke);
    }
    canvas.restore();
  }

  void _unknown(Canvas canvas, Paint fill, Paint stroke) {
    // Dotted like the offline lamp's ring, so it reads as "not known" rather than as a system.
    final dots = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke.strokeWidth;
    final ring = Rect.fromCircle(center: const Offset(12, 12), radius: 10.4);
    const n = 12;
    for (var i = 0; i < n; i++) {
      canvas.drawArc(ring, i * 2 * math.pi / n, .01, false, dots);
    }
    final q = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke.strokeWidth * .9;
    canvas.drawPath(
      Path()
        ..moveTo(9, 9.4)
        ..arcToPoint(const Offset(15, 9.4), radius: const Radius.circular(3))
        ..cubicTo(15, 11.4, 12, 11.6, 12, 13.8),
      q,
    );
    canvas.drawCircle(const Offset(12, 17.4), stroke.strokeWidth * .55, fill);
  }

  @override
  bool shouldRepaint(OsMarkPainter old) => old.os != os || old.color != color || old.size != size;
}

/// An apple with a bite and a leaf.
Path _apple() {
  final body = Path.combine(
    PathOperation.union,
    Path()..addOval(Rect.fromCenter(center: const Offset(9.4, 14.6), width: 11, height: 13)),
    Path()..addOval(Rect.fromCenter(center: const Offset(14.6, 14.6), width: 11, height: 13)),
  );
  final bitten = Path.combine(
    PathOperation.difference,
    body,
    Path()..addOval(Rect.fromCircle(center: const Offset(21.4, 12.4), radius: 3.1)),
  );
  return bitten
    ..addPath(
      Path()
        ..moveTo(12.2, 7.1)
        ..cubicTo(11.8, 4.6, 13.6, 2.7, 16.2, 2.5)
        ..cubicTo(16.4, 5, 14.7, 6.9, 12.2, 7.1)
        ..close(),
      Offset.zero,
    );
}

/// A tablet or phone body with [mark] cut out of its screen, [share] of its width. Cut out rather than drawn
/// inside an outline: at the lamp's size an outline leaves the mark a few pixels and it turns to a blot.
Path _device(Rect r, double radius, double share, Path mark) {
  final b = mark.getBounds();
  final k = r.width * share / b.width;
  final m = Matrix4.identity()
    ..translateByDouble(r.center.dx, r.center.dy, 0, 1)
    ..scaleByDouble(k, k, 1, 1)
    ..translateByDouble(-b.center.dx, -b.center.dy, 0, 1);
  return Path.combine(
    PathOperation.difference,
    Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(radius))),
    mark.transform(m.storage),
  );
}

/// Four panes, 2×2 with gaps.
Path _panes() {
  const a = 3.5, b = 11.2, c = 12.8, d = 20.5;
  return Path()
    ..addRect(const Rect.fromLTRB(a, a, b, b))
    ..addRect(const Rect.fromLTRB(c, a, d, b))
    ..addRect(const Rect.fromLTRB(a, c, b, d))
    ..addRect(const Rect.fromLTRB(c, c, d, d));
}

/// Omarchy's mark, simplified from the project's own: a square inside a square, each line broken where the
/// original is open (the outer one at the top and the bottom, the inner one at its top right). Drawn as lines
/// of the lamp's weight; the original's thin double lines blur together at this size.
Path _omarchy() {
  const o0 = 2.0, o1 = 22.0, i0 = 7.2, i1 = 16.8;
  return Path()
    ..moveTo(13.6, o0)
    ..lineTo(o1, o0)
    ..lineTo(o1, o1)
    ..lineTo(15.6, o1)
    ..moveTo(12.4, o1)
    ..lineTo(o0, o1)
    ..lineTo(o0, o0)
    ..lineTo(10.4, o0)
    ..moveTo(15.2, i0)
    ..lineTo(i1, i0)
    ..lineTo(i1, i1)
    ..lineTo(i0, i1)
    ..lineTo(i0, i0)
    ..lineTo(12.4, i0);
}

/// A penguin: head and body in one, the belly left open, two feet.
Path _penguin() {
  final figure = Path.combine(
    PathOperation.union,
    Path()..addOval(Rect.fromCircle(center: const Offset(12, 6.6), radius: 4.3)),
    Path()..addOval(Rect.fromCenter(center: const Offset(12, 14.6), width: 13, height: 14.6)),
  );
  final bellied = Path.combine(
    PathOperation.difference,
    figure,
    Path()..addOval(Rect.fromCenter(center: const Offset(12, 15.6), width: 7.4, height: 9.6)),
  );
  return Path.combine(
    PathOperation.union,
    bellied,
    Path()
      ..addOval(Rect.fromCenter(center: const Offset(8.4, 21.4), width: 6.4, height: 3))
      ..addOval(Rect.fromCenter(center: const Offset(15.6, 21.4), width: 6.4, height: 3)),
  );
}

/// The Android robot's head: a half disc, two feelers, eyes cut out.
Path _robot() {
  final head = Path()
    ..moveTo(2.5, 17)
    ..arcToPoint(const Offset(21.5, 17), radius: const Radius.circular(9.5))
    ..close();
  Path feeler(Offset from, Offset to) {
    final d = to - from;
    final n = Offset(-d.dy, d.dx) / d.distance * 1.3;
    return Path()
      ..moveTo(from.dx + n.dx, from.dy + n.dy)
      ..lineTo(to.dx + n.dx, to.dy + n.dy)
      ..lineTo(to.dx - n.dx, to.dy - n.dy)
      ..lineTo(from.dx - n.dx, from.dy - n.dy)
      ..close();
  }

  final withFeelers = Path.combine(
    PathOperation.union,
    head,
    feeler(const Offset(7.4, 10), const Offset(4.6, 4.6))..addPath(feeler(const Offset(16.6, 10), const Offset(19.4, 4.6)), Offset.zero),
  );
  return Path.combine(
    PathOperation.difference,
    withFeelers,
    Path()
      ..addOval(Rect.fromCircle(center: const Offset(8, 12.6), radius: 1.4))
      ..addOval(Rect.fromCircle(center: const Offset(16, 12.6), radius: 1.4)),
  );
}
