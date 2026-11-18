import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/voice_ring.dart';

Offset polar(Offset c, double radius, double a) =>
    c + Offset(math.sin(a), -math.cos(a)) * radius;

double deg(double d) => d * math.pi / 180;

List<Offset> sample(Path p) {
  final out = <Offset>[];
  for (final m in p.computeMetrics()) {
    for (var d = 0.0; d <= m.length; d += 1) {
      out.add(m.getTangentForOffset(d)!.position);
    }
  }
  return out;
}

double length(Path p) =>
    p.computeMetrics().fold(0.0, (s, m) => s + m.length);

void main() {
  const stage = Size(400, 900);
  final right = VoiceRing(stage: stage, thumb: const Offset(356, 812), right: true);
  final left = VoiceRing(stage: stage, thumb: const Offset(44, 812), right: false);

  test('radius, band and centre follow the spec', () {
    expect(right.r, closeTo(440, 1e-6));
    expect(right.band, closeTo(49.7, .1));
    expect(right.centre.dx, 356);
    expect(right.centre.dy - right.r, closeTo(812 - 84, 1e-6));
    expect(right.inner, closeTo(1.033 * 440, 1e-9));
    expect(right.axis, closeTo(deg(-22.5), 1e-9));
  });

  test('iPad landscape: r = 0.9*H', () {
    final ring = VoiceRing(
        stage: const Size(1180, 820), thumb: const Offset(1136, 756), right: true);
    expect(ring.r, closeTo(738, 1e-6));
  });

  void picks(VoiceRing ring, double towardUp) {
    expect(ring.pick(ring.thumb), VoicePick.send);
    final edit = polar(ring.centre, ring.r + 5, ring.axis + towardUp * deg(10));
    final cancel = polar(ring.centre, ring.r + 5, ring.axis - towardUp * deg(10));
    expect(ring.pick(edit), VoicePick.edit);
    expect(ring.pick(cancel), VoicePick.cancel);
  }

  test('the thumb picks send; out past the edge, the vertical side is edit', () {
    picks(right, 1);
  });

  test('left hand mirrors', () {
    expect(left.axis, closeTo(deg(22.5), 1e-9));
    picks(left, -1);
  });

  for (final ring in [right, left]) {
    test('segments stay inside the band and keep the gap (right=${ring.right})', () {
      for (final w in [VoicePick.edit, VoicePick.cancel]) {
        for (final p in sample(ring.segment(w))) {
          final d = (p - ring.centre).distance;
          expect(d, inInclusiveRange(ring.inner - .5, ring.inner + ring.band + .5));
        }
      }
      // Tip = sample point closest to the axis.
      Offset tip(VoicePick w) {
        final pts = sample(ring.segment(w));
        double off(Offset p) {
          final v = p - ring.centre;
          var a = math.atan2(v.dx, -v.dy) - ring.axis;
          while (a > math.pi) {
            a -= 2 * math.pi;
          }
          while (a < -math.pi) {
            a += 2 * math.pi;
          }
          return a.abs();
        }

        return pts.reduce((a, b) => off(a) < off(b) ? a : b);
      }

      final gap = (tip(VoicePick.edit) - tip(VoicePick.cancel)).distance;
      expect(gap, greaterThanOrEqualTo(0.059 * ring.r - 1));
    });

    test('sweep 0 is empty, 1 is 19 deg long (right=${ring.right})', () {
      expect(length(ring.segment(VoicePick.edit, sweep: 0)), 0);
      final full = sample(ring.segment(VoicePick.edit));
      final tipSide = ring.axis;
      var maxA = 0.0;
      for (final p in full) {
        final v = p - ring.centre;
        maxA = math.max(maxA, (math.atan2(v.dx, -v.dy) - tipSide).abs());
      }
      final mid = ring.inner + ring.band / 2;
      final head = 0.36 * ring.band / mid;
      // far end = tip root + 19 deg; tip root = axis offset + depth/mid.
      final expected = (0.0295 * ring.r + 0.36 * ring.band) / mid + deg(19);
      expect(maxA, closeTo(expected, deg(0.3)));
      expect(head, greaterThan(0));
      final half = length(ring.segment(VoicePick.edit, sweep: .5));
      expect(half, greaterThan(0));
      expect(half, lessThan(length(ring.segment(VoicePick.edit))));
    });

    test('probe maps back to its own pick (right=${ring.right})', () {
      for (final w in VoicePick.values) {
        expect(ring.pick(ring.probe(w)), w);
      }
    });
  }
}
