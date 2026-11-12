// Pure pointer rules for the embedded picture: click counting and scroll direction.
import 'dart:ui';

/// Counts double and triple clicks (Flutter's pointer events carry no click count, R14): a press
/// is the next click of a run when it uses the same button, comes within [interval] of the
/// previous press and lands within [slop] logical pixels of it.
class ClickCounter {
  ClickCounter(this.interval, {this.slop = 4});

  final Duration interval;
  final double slop;

  Offset? _at;
  Duration? _time;
  int _button = 0;
  int _count = 0;

  /// The click count for a press of [button] (a `kPrimaryButton`-style bit) at [p], [time].
  int down(Offset p, Duration time, int button) {
    final at = _at, last = _time;
    final next = at != null &&
        last != null &&
        button == _button &&
        time - last <= interval &&
        time >= last &&
        (p - at).distance <= slop;
    _count = next ? _count + 1 : 1;
    _at = p;
    _time = time;
    _button = button;
    return _count;
  }
}

/// A mouse wheel's scroll delta for A: Flutter's points the other way from AppKit's.
Offset wheelToRemote(Offset scrollDelta) => -scrollDelta;

/// A trackpad pan's delta for A: already the way AppKit's scrolling deltas go.
Offset panToRemote(Offset localPanDelta) => localPanDelta;

/// [p] moved inside [r] (a drag that left the picture stays on its edge).
Offset clampTo(Offset p, Rect r) => Offset(p.dx.clamp(r.left, r.right), p.dy.clamp(r.top, r.bottom));
