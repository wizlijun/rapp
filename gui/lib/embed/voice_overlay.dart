// The hold-to-talk screen (voice-input spec §5.1): the scrim, the send disc that grows out of the voice button,
// the 编辑 / 取消 bands, and the bubble with the words, the level bars and the 「松手 …」 line. Minimal: flat
// fills and 1 px lines; the only gradient is the bands' outward fade.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ui/tokens.dart';
import 'stage_buttons.dart';
import 'voice_button.dart';
import 'voice_input.dart';
import 'voice_ring.dart';

const _press = Duration(milliseconds: 240);
const _release = Duration(milliseconds: 200);
const _bars = 24;
const _segmentDeg = 19.0;
const _tail = 6.0;

String voiceHintLine(VoicePick p) => switch (p) {
  VoicePick.send => '松手 发送',
  VoicePick.cancel => '松手 取消',
  VoicePick.edit => '松手 改一改再发',
};

/// Over the whole stage. Shows while [hold] holds and through the release; otherwise it is an empty box
/// that only lends its size and place to the hold (`hold.stageKey`).
class VoiceOverlay extends StatefulWidget {
  const VoiceOverlay({super.key, required this.hold, required this.voice});

  final VoiceHold hold;
  final VoiceInput voice;

  @override
  State<VoiceOverlay> createState() => _VoiceOverlayState();
}

class _VoiceOverlayState extends State<VoiceOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _press, reverseDuration: _release);
  bool _up = false;
  bool _releasing = false;
  VoicePick _released = VoicePick.send;
  double _fromValue = 1;
  double _fromSweep = 1;
  bool _reduced = false;
  List<double> _levels = List.filled(_bars, 0);
  // The words as they were when the release began: the bubble keeps them while it fades (a cancel clears them).
  String _said = '';
  (String, double, String)? _tailKey;

  VoiceHold get _hold => widget.hold;

  @override
  void initState() {
    super.initState();
    _hold.addListener(_onHold);
    widget.voice.level.addListener(_onLevel);
    _c.addListener(_onTick);
    _c.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(VoiceOverlay old) {
    super.didUpdateWidget(old);
    if (old.hold != widget.hold) {
      old.hold.removeListener(_onHold);
      widget.hold.addListener(_onHold);
    }
    if (old.voice != widget.voice) {
      old.voice.level.removeListener(_onLevel);
      widget.voice.level.addListener(_onLevel);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void dispose() {
    _hold.removeListener(_onHold);
    widget.voice.level.removeListener(_onLevel);
    _c.dispose();
    super.dispose();
  }

  void _onHold() {
    if (_hold.holding && !_up) {
      _up = true;
      _releasing = false;
      _levels = List.filled(_bars, 0);
      _said = '';
      _hold.showing = true;
      if (_reduced) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    } else if (!_hold.holding && _up) {
      _up = false;
      _releasing = true;
      _released = _hold.pick;
      // The bands go out from where they are; a release mid-press does not finish their sweep first.
      _fromValue = _c.value;
      _fromSweep = _pressSweep(_c.value);
      if (_reduced) {
        _c.value = 0;
      } else {
        _c.reverse();
      }
    }
    if (mounted) setState(() {});
  }

  // The bands sweep in over the last 120 ms of the 240 ms press.
  double _pressSweep(double v) => ((v * _press.inMilliseconds - 120) / 120).clamp(0.0, 1.0);

  void _onLevel() {
    // The bars stop while 取消 is picked.
    if (!_up || _hold.pick == VoicePick.cancel) return;
    setState(() => _levels = [..._levels.skip(1), widget.voice.level.value]);
  }

  void _onTick() {
    final v = _c.value;
    // The release ends the moment the disc is back (the controller itself reports it a frame later).
    if (_releasing && !_up && v == 0) {
      _c.stop();
      _done();
      return;
    }
    // The icon goes in the first 80 ms of the press and comes back in the last 80 ms of the release.
    _hold.buttonOpacity.value = _releasing
        ? 1 - (v / (80 / 200)).clamp(0.0, 1.0)
        : 1 - (v / (80 / 240)).clamp(0.0, 1.0);
  }

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.dismissed && !_up) _done();
  }

  void _done() {
    if (!_releasing) return;
    _releasing = false;
    _hold.buttonOpacity.value = 1;
    _hold.showing = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ring = _hold.ring;
    final shown = (_up || _hold.showing) && ring != null;
    return AbsorbPointer(
      absorbing: shown,
      child: SizedBox.expand(
        key: _hold.stageKey,
        child: shown
            ? ClipRect(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_c, widget.voice]),
                  builder: (context, _) => LayoutBuilder(builder: (context, c) => _frame(context, ring, c.biggest)),
                ),
              )
            : null,
      ),
    );
  }

  Widget _frame(BuildContext context, VoiceRing ring, Size stage) {
    final t = RappTokens.of(context);
    final v = _c.value;
    final double morph, scrim, bubble, rise, sweep, bands;
    if (_releasing) {
      // Time since the release began (a release mid-press starts below 1).
      final ms = (_fromValue - v) * _release.inMilliseconds;
      morph = 1 - Curves.easeInCubic.transform(1 - v);
      scrim = v;
      bubble = v;
      // Sent: the bubble rises as it fades, as if sent off; otherwise it fades where it is.
      rise = _released == VoicePick.send ? -8 * (1 - v) : 0;
      sweep = _fromSweep;
      bands = _fromSweep * (1 - ms / 100).clamp(0.0, 1.0);
    } else {
      final ms = v * _press.inMilliseconds;
      morph = Curves.easeOutCubic.transform(v);
      scrim = (ms / 160).clamp(0.0, 1.0);
      bubble = ((ms - 80) / 160).clamp(0.0, 1.0);
      rise = 8 * (1 - bubble);
      sweep = _pressSweep(v);
      bands = sweep;
    }
    final pick = _releasing ? _released : _hold.pick;
    final right = ring.right;
    // Above the higher of the two full bands: the 编辑 band climbs past the outer edge at the gap axis.
    final bandTop = math.min(ring.segment(VoicePick.edit).getBounds().top, ring.segment(VoicePick.cancel).getBounds().top);
    final width = math.min(stage.width - 32, 600.0);
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            key: const Key('voice-ring'),
            painter: VoiceRingPainter(
              ring: ring,
              pick: pick,
              progress: morph,
              tokens: t,
              scrim: scrim,
              sweep: sweep,
              bands: bands,
            ),
          ),
        ),
        Positioned(
          left: right ? null : 16,
          right: right ? 16 : null,
          width: width,
          bottom: stage.height - (bandTop - 12),
          child: Opacity(
            opacity: bubble,
            child: Transform.translate(
              offset: Offset(0, _reduced ? 0 : rise),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: right ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  _bubble(context, t, pick, width, right),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(voiceHintLine(pick), style: TextStyle(color: t.text, fontSize: 13, height: 1.4)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bubble(BuildContext context, RappTokens t, VoicePick pick, double width, bool right) {
    final (fill, ink, border) = switch (pick) {
      VoicePick.send => (t.text, t.bg, null),
      VoicePick.cancel => (t.raise.first, t.muted, t.line),
      VoicePick.edit => (t.float.first, t.text, t.text),
    };
    final style = TextStyle(color: ink, fontSize: 17, height: 1.35);
    // Holding: the live words. Releasing: the last of them, kept (a native error has already cleared the text).
    final said = _releasing ? _said : (_said = widget.voice.text);
    final words = said.isEmpty ? '正在听…' : _tailOf(said, style, width - 32, MediaQuery.textScalerOf(context));
    return CustomPaint(
      painter: VoiceBubbleFrame(fill: fill, border: border, dashed: pick == VoicePick.edit, right: right, radius: t.r),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12 + _tail),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            pick == VoicePick.edit
                ? Text.rich(
                    TextSpan(
                      text: words,
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: SizedBox(width: 1.5, height: 20, child: ColoredBox(color: t.text)),
                        ),
                      ],
                    ),
                    style: style,
                  )
                : Text(words, style: style),
            const SizedBox(height: 8),
            Align(
              alignment: right ? Alignment.centerRight : Alignment.centerLeft,
              child: CustomPaint(
                key: const Key('voice-bars'),
                size: const Size(_bars * 4 - 2, 20),
                painter: VoiceBarsPainter(
                  level: widget.voice.level.value,
                  levels: _levels,
                  color: ink,
                  still: pick == VoicePick.cancel,
                  right: right,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // At most 4 lines: the end of what was said (see [voiceTail]); the last answer is kept.
  String _tailOf(String s, TextStyle style, double width, TextScaler scaler) {
    final k = _tailKey;
    if (k != null && k.$1 == s && k.$2 == width) return k.$3;
    final out = voiceTail(s, style, width, scaler);
    _tailKey = (s, width, out);
    return out;
  }
}

/// At most 4 lines: the end of what was said, with … in front when the start is cut.
String voiceTail(String s, TextStyle style, double width, TextScaler scaler) {
  bool fits(int from) {
    final tp = TextPainter(
      text: TextSpan(text: from == 0 ? s : '…${s.substring(from)}', style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 4,
    )..layout(maxWidth: width);
    final ok = !tp.didExceedMaxLines;
    tp.dispose();
    return ok;
  }

  if (fits(0)) return s;
  var lo = 1, hi = s.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (fits(mid)) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  // Do not start in the middle of a surrogate pair.
  if (lo < s.length && (s.codeUnitAt(lo) & 0xFC00) == 0xDC00) lo++;
  return '…${s.substring(lo)}';
}

/// The scrim, the send disc ([progress] 0 is the voice button, 1 the full disc) and the two bands.
class VoiceRingPainter extends CustomPainter {
  VoiceRingPainter({
    required this.ring,
    required this.pick,
    required this.progress,
    required this.tokens,
    this.scrim = 1,
    this.sweep = 1,
    this.bands = 1,
  });

  final VoiceRing ring;
  final VoicePick pick;
  final double progress;
  final RappTokens tokens;

  /// The scrim's share of its 60 %, how far the bands have grown (0–1), and their opacity.
  final double scrim, sweep, bands;

  /// The band for [which] as drawn: the ring's own segment, so it lies on the side [VoiceRing.pick] gives it.
  @visibleForTesting
  Path bandPath(VoicePick which) => ring.segment(which, sweep: sweep);

  @override
  void paint(Canvas canvas, Size size) {
    final t = tokens;
    canvas.drawRect(Offset.zero & size, Paint()..color = t.bg.withValues(alpha: .6 * scrim));
    final centre = Offset.lerp(ring.thumb, ring.centre, progress)!;
    final radius = ui.lerpDouble(stageButtonSize / 2, ring.r, progress)!;
    final send = pick == VoicePick.send;
    canvas.drawCircle(centre, radius, Paint()..color = t.raise.first);
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = send ? 1.5 : 1
        ..color = send ? t.text : t.line,
    );
    if (bands <= 0 || sweep <= 0) return;
    for (final which in const [VoicePick.edit, VoicePick.cancel]) {
      _band(canvas, which);
    }
  }

  // Angle from straight up, clockwise, about the ring's centre.
  double _angle(Offset p) => math.atan2(p.dx - ring.centre.dx, -(p.dy - ring.centre.dy));

  void _band(Canvas canvas, VoicePick which) {
    final t = tokens;
    final path = bandPath(which);
    final on = pick == which;
    final paint = Paint();
    if (on) {
      paint.color = t.accent.withValues(alpha: t.accent.a * bands);
    } else {
      // Solid for 55 % of the segment from its head, then fading to about 8 % at the far end.
      final metric = path.computeMetrics().first;
      final root = _angle(metric.getTangentForOffset(0)!.position);
      final d = (ring.labelTurn(which) - ring.axis).sign;
      final end = root + d * _segmentDeg * math.pi / 180;
      var a0 = math.min(root, end) - math.pi / 2;
      var a1 = math.max(root, end) - math.pi / 2;
      while (a0 < 0) {
        a0 += 2 * math.pi;
        a1 += 2 * math.pi;
      }
      // The band's opacity rides on the stops (a token colour, no literal paint colour).
      final c = t.raise.first.withValues(alpha: t.raise.first.a * bands);
      final faded = c.withValues(alpha: c.a * .08);
      paint.shader = ui.Gradient.sweep(
        ring.centre,
        d > 0 ? [c, c, faded] : [faded, c, c],
        d > 0 ? const [0, .55, 1] : const [0, .45, 1],
        TileMode.clamp,
        a0,
        a1,
      );
    }
    canvas.drawPath(path, paint);
    _label(canvas, which, on ? t.accentInk : t.text);
  }

  void _label(Canvas canvas, VoicePick which, Color ink) {
    final a = (bands * sweep).clamp(0.0, 1.0);
    if (a <= 0) return;
    final color = ink.withValues(alpha: ink.a * a);
    final icon = which == VoicePick.edit ? Icons.edit_outlined : Icons.close;
    final glyph = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: 16, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final word = TextPainter(
      text: TextSpan(
        text: which == VoicePick.edit ? '编辑' : '取消',
        style: TextStyle(fontSize: 15, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const gap = 4.0;
    final w = glyph.width + gap + word.width;
    canvas.save();
    final at = ring.labelAt(which);
    canvas.translate(at.dx, at.dy);
    canvas.rotate(ring.labelTurn(which));
    glyph.paint(canvas, Offset(-w / 2, -glyph.height / 2));
    word.paint(canvas, Offset(-w / 2 + glyph.width + gap, -word.height / 2));
    canvas.restore();
    glyph.dispose();
    word.dispose();
  }

  @override
  bool shouldRepaint(VoiceRingPainter old) =>
      old.ring != ring ||
      old.pick != pick ||
      old.progress != progress ||
      old.tokens != tokens ||
      old.scrim != scrim ||
      old.sweep != sweep ||
      old.bands != bands;
}

/// The 24 level bars in the bubble: the last 24 microphone levels, newest at the thumb's end ([right]: the
/// right hand, newest rightmost). [still] (取消) lays them flat.
class VoiceBarsPainter extends CustomPainter {
  VoiceBarsPainter({required this.level, required this.levels, required this.color, this.still = false, this.right = true});

  /// The microphone level now, 0–1.
  final double level;
  final List<double> levels;
  final Color color;
  final bool still, right;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final n = levels.length;
    for (var i = 0; i < n; i++) {
      // A fixed unevenness, so a steady voice still reads as a waveform.
      final shape = .55 + .45 * (math.sin(i * 1.7)).abs();
      final h = still ? 2.0 : math.max(2.0, size.height * (.12 + .88 * levels[i] * shape));
      final x = (right ? i : n - 1 - i) * 4.0;
      canvas.drawRect(Rect.fromLTWH(x, (size.height - h) / 2, 2, h), paint);
    }
  }

  @override
  bool shouldRepaint(VoiceBarsPainter old) =>
      old.level != level ||
      !identical(old.levels, levels) ||
      old.color != color ||
      old.still != still ||
      old.right != right;
}

/// The bubble's shape: a rounded box with a small tail at the bottom on the thumb's side; filled, with an
/// optional 1 px border (dashed for 编辑).
class VoiceBubbleFrame extends CustomPainter {
  VoiceBubbleFrame({
    required this.fill,
    required this.border,
    required this.dashed,
    required this.right,
    required this.radius,
    this.tail = true,
  });

  final Color fill;
  final Color? border;
  final bool dashed, right;
  final double radius;

  /// The small tail at the bottom; without it the bubble is a plain rounded box (the Mac's).
  final bool tail;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTWH(0, 0, size.width, size.height - (tail ? _tail : 0));
    final tx = right ? size.width - 24 : 24.0;
    final body = Path()..addRRect(RRect.fromRectAndRadius(box.deflate(.5), Radius.circular(radius)));
    final shape = !tail
        ? body
        : Path.combine(
            PathOperation.union,
            body,
            Path()
              ..moveTo(tx - 6, box.bottom)
              ..lineTo(tx, size.height)
              ..lineTo(tx + 6, box.bottom)
              ..close(),
          );
    canvas.drawPath(shape, Paint()..color = fill);
    final b = border;
    if (b == null) return;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = b;
    if (!dashed) {
      canvas.drawPath(shape, stroke);
      return;
    }
    for (final m in shape.computeMetrics()) {
      for (var at = 0.0; at < m.length; at += 7) {
        canvas.drawPath(m.extractPath(at, math.min(at + 4, m.length)), stroke);
      }
    }
  }

  @override
  bool shouldRepaint(VoiceBubbleFrame old) =>
      old.tail != tail ||
      old.fill != fill || old.border != border || old.dashed != dashed || old.right != right || old.radius != radius;
}
