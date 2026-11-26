// The system mark beside a device's lamp on the overview (全景): one colour, the lamp's size. The marks are the
// makers' own (os_mark_paths.dart); tablets and phones are a device body with that mark cut out of it.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'device_os.dart';
import 'os_mark_paths.dart';
import 'svg_path.dart';
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
      excludeFromSemantics: true, // the Semantics below says it; once is enough
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
      case DeviceOs.unknown:
        _unknown(canvas, fill, stroke);
      default:
        canvas.drawPath(_paths[os]!, fill);
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

/// Built once: a spinning lamp beside the mark repaints it every frame, and the path ops are not free.
final Map<DeviceOs, Path> _paths = () {
  final apple = parseSvgPath(appleSvg), android = parseSvgPath(androidSvg);
  return {
    DeviceOs.macos: apple,
    DeviceOs.windows: parseSvgPath(windowsSvg),
    DeviceOs.omarchy: parseSvgPath(omarchySvg),
    DeviceOs.linux: parseSvgPath(linuxSvg),
    DeviceOs.ipad: _device(const Rect.fromLTWH(3, 1, 18, 22), 3, .62, apple),
    DeviceOs.androidTablet: _device(const Rect.fromLTWH(3, 1, 18, 22), 3, .66, android),
    DeviceOs.iphone: _device(const Rect.fromLTWH(6, 0.5, 12, 23), 3.2, .7, apple),
    DeviceOs.androidPhone: _device(const Rect.fromLTWH(6, 0.5, 12, 23), 3.2, .74, android),
  };
}();

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
