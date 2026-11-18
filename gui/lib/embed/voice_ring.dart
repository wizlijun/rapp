import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// What the finger is over while the voice disc is up.
enum VoicePick { send, edit, cancel }

/// The geometry of the hold-to-talk screen: a send disc under the thumb, and outside it a concentric band
/// split by a gap into two segments, 编辑 (nearer straight up) and 取消. Pure geometry, no widgets.
///
/// Angles are in radians from straight up, positive clockwise. [right] means the hand edge is the right one.
class VoiceRing {
  VoiceRing({required Size stage, required this.thumb, required this.right}) {
    r = math.min(1.1 * stage.width, 0.9 * stage.height);
    final apex = math.max(0.23 * r - 44, 84.0);
    centre = Offset(thumb.dx, thumb.dy - apex + r);
    inner = 1.033 * r;
    band = math.max(0.113 * r, 48.0);
    axis = _rad(right ? -22.5 : 22.5);
  }

  final Offset thumb;
  final bool right;

  /// The disc radius.
  late final double r;
  late final Offset centre;
  late final double inner;
  late final double band;

  /// The gap axis.
  late final double axis;

  static const _segment = 19.0;
  static const _labelAt = 12.0;

  static double _rad(double d) => d * math.pi / 180;

  double get _mid => inner + band / 2;
  double get _depth => 0.36 * band;

  /// +1 when straight up lies at larger angles than the axis (right hand), else -1.
  double get _toUp => right ? 1 : -1;

  /// The direction a segment runs from the axis: edit toward straight up, cancel away from it.
  double _dir(VoicePick which) {
    assert(which != VoicePick.send);
    return which == VoicePick.edit ? _toUp : -_toUp;
  }

  Offset _polar(double radius, double a) =>
      centre + Offset(math.sin(a), -math.cos(a)) * radius;

  VoicePick pick(Offset p) {
    final v = p - centre;
    if (v.distance <= r) return VoicePick.send;
    var d = math.atan2(v.dx, -v.dy) - axis;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    return d * _toUp > 0 ? VoicePick.edit : VoicePick.cancel;
  }

  /// The band polygon: outer arc, far end, inner arc back, then the flattened round head. It is
  /// 19 degrees long times [sweep] from the tip root.
  Path segment(VoicePick which, {double sweep = 1}) {
    final d = _dir(which);
    final path = Path();
    if (sweep <= 0) return path;
    final outer = inner + band;
    final root = axis + d * (0.0295 * r + _depth) / _mid;
    final len = _rad(_segment) * sweep.clamp(0.0, 1.0);
    final end = root + d * len;
    Rect circle(double radius) => Rect.fromCircle(center: centre, radius: radius);
    // Canvas arc angles start at +x; ours start at straight up.
    final start = root - math.pi / 2;
    path.moveTo(_polar(outer, root).dx, _polar(outer, root).dy);
    path.arcTo(circle(outer), start, d * len, false);
    final e = _polar(inner, end);
    path.lineTo(e.dx, e.dy);
    path.arcTo(circle(inner), end - math.pi / 2, -d * len, false);
    const steps = 16;
    for (var i = 0; i <= steps; i++) {
      final t = -1 + 2 * i / steps;
      final radius = _mid + t * band / 2;
      final a = root - d * _depth * math.sqrt(math.max(0, 1 - t * t)) / radius;
      final q = _polar(radius, a);
      path.lineTo(q.dx, q.dy);
    }
    path.close();
    return path;
  }

  double _labelAngle(VoicePick which) => axis + _dir(which) * _rad(_labelAt);

  Offset labelAt(VoicePick which) => _polar(_mid, _labelAngle(which));

  /// The tangent rotation of the label at [labelAt].
  double labelTurn(VoicePick which) => _labelAngle(which);

  @visibleForTesting
  Offset probe(VoicePick which) =>
      which == VoicePick.send ? thumb : labelAt(which);
}
