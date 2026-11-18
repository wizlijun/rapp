// Per-window zoom on B: how far a window is zoomed, where, and when A is told which part is seen.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// The zoom state of one window: factor [z] (1–[maxZoom]) and [centre], the content point at the
/// stage's centre (0–1 of the content). Only the picture's size and place on the stage follow from it.
class ZoomView extends ChangeNotifier {
  static const maxZoom = 4.0;
  static const _restoreTime = Duration(milliseconds: 200);
  static const _backdropTail = Duration(seconds: 1);

  double _z = 1;
  Offset _centre = const Offset(0.5, 0.5);
  bool _restoring = false;
  bool _tail = false;
  bool _disposed = false;
  Timer? _tailTimer;
  int _run = 0;

  double get z => _z;
  Offset get centre => _centre;
  bool get zoomed => _z > 1;
  bool get restoring => _restoring;

  /// The backdrop (the low-res base picture) is wanted: zoomed, restoring, or within 1 s after a restore.
  bool get backdrop => zoomed || _restoring || _tail;

  /// Where the window's content is on the stage: [fit] at z 1, else scaled about the stage centre and
  /// held inside the stage. [keyboard] only lowers the bottom bound; it never moves the view.
  Rect zfit(Rect fit, Size stage, {double keyboard = 0}) {
    if (_z == 1) return fit;
    final w = fit.width * _z, h = fit.height * _z;
    return _clamped(stage.width / 2 - _centre.dx * w, stage.height / 2 - _centre.dy * h, w, h, stage, keyboard);
  }

  static Rect _clamped(double left, double top, double w, double h, Size stage, double keyboard) {
    final l = left.clamp(math.min(0.0, stage.width - w), math.max(0.0, stage.width - w)).toDouble();
    final t = top.clamp(math.min(0.0, stage.height - keyboard - h), math.max(0.0, stage.height - h)).toDouble();
    return Rect.fromLTWH(l, t, w, h);
  }

  void _setCentreFrom(Rect r, Size stage) {
    _centre = Offset((stage.width / 2 - r.left) / r.width, (stage.height / 2 - r.top) / r.height);
  }

  /// Zooms to [z] (clamped to 1–4) keeping the content point under [focal] where it is.
  void zoomTo(double z, Offset focal, Rect fit, Size stage, {double keyboard = 0}) {
    _stopRestore();
    final before = zfit(fit, stage, keyboard: keyboard);
    final fx = (focal.dx - before.left) / before.width;
    final fy = (focal.dy - before.top) / before.height;
    _z = z.clamp(1.0, maxZoom).toDouble();
    if (_z == 1) {
      // A finished restore() deliberately keeps its centre; z 1 ignores the centre, so this reset is harmless.
      _centre = const Offset(0.5, 0.5);
    } else {
      final w = fit.width * _z, h = fit.height * _z;
      _setCentreFrom(_clamped(focal.dx - fx * w, focal.dy - fy * h, w, h, stage, keyboard), stage);
    }
    notifyListeners();
  }

  /// Moves the picture by [delta] on the stage, stopping at the edges; the centre follows the held rect.
  void panBy(Offset delta, Rect fit, Size stage, {double keyboard = 0}) {
    if (!zoomed) return;
    _stopRestore();
    final r = zfit(fit, stage, keyboard: keyboard);
    _setCentreFrom(_clamped(r.left + delta.dx, r.top + delta.dy, r.width, r.height, stage, keyboard), stage);
    notifyListeners();
  }

  void _stopRestore() {
    _run++;
    _restoring = false;
  }

  /// Back to z 1 in 200 ms, the centre kept; notifies on every frame.
  void restore() {
    if (!zoomed || _restoring) return;
    _tailTimer?.cancel();
    _tail = false;
    _restoring = true;
    final run = ++_run;
    final z0 = _z;
    Duration? start;
    void frame(Duration ts) {
      if (_disposed || run != _run) return;
      start ??= ts;
      final t = ((ts - start!).inMicroseconds / _restoreTime.inMicroseconds).clamp(0.0, 1.0);
      if (t >= 1) {
        _z = 1;
        _restoring = false;
        _tail = true;
        _tailTimer = Timer(_backdropTail, () {
          _tail = false;
          if (!_disposed) notifyListeners();
        });
      } else {
        _z = z0 + (1 - z0) * t;
        SchedulerBinding.instance.scheduleFrameCallback(frame);
      }
      notifyListeners();
    }

    SchedulerBinding.instance.scheduleFrameCallback(frame);
    notifyListeners();
  }

  /// Takes [other]'s z and centre as they are (no animation).
  void adopt(ZoomView other) {
    _stopRestore();
    _z = other._z;
    _centre = other._centre;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tailTimer?.cancel();
    super.dispose();
  }
}

/// [seen] widened by 25 % of its width and height on each side, kept inside the content.
Rect viewRange(Rect seen, Size content) {
  final r = seen;
  final wide = Rect.fromLTRB(
      r.left - r.width * 0.25, r.top - r.height * 0.25, r.right + r.width * 0.25, r.bottom + r.height * 0.25);
  return wide.intersect(Offset.zero & content);
}

/// The factor A really works with: [z], but no more than what would fill the content's pixels with [range].
double viewFactor(double z, Rect range, Size content) {
  final a = range.width * range.height;
  if (a <= 0) return z;
  return math.min(z, math.sqrt(content.width * content.height / a));
}

/// Decides when A is told the part of a window that is seen: only when what is seen leaves the range
/// A was last told, or the factor moves by more than 10 %.
class ViewLink {
  ViewLink(this._send);

  final void Function(int window, Rect rect, double zoom) _send;
  ({int window, Rect range, double zoom, double factor})? _last;

  /// The view stopped moving: [seen] (content points) of [window], zoomed [z].
  void settled(int window, Rect seen, Size content, double z) {
    if (z <= 1) {
      unlimited();
      return;
    }
    final range = viewRange(seen, content);
    final factor = viewFactor(z, range, content);
    final last = _last;
    if (last != null && last.window == window && _inside(seen, last.range) &&
        (factor - last.factor).abs() / last.factor <= 0.1) {
      return;
    }
    _last = (window: window, range: range, zoom: z, factor: factor);
    _send(window, range, z);
  }

  static bool _inside(Rect a, Rect b) => a.left >= b.left && a.top >= b.top && a.right <= b.right && a.bottom <= b.bottom;

  /// Back to the whole window (only said when a range was set).
  void unlimited() {
    if (_last == null) return;
    _last = null;
    _send(0, Rect.zero, 1);
  }

  /// The link is new: say the last range again.
  void resend() {
    final l = _last;
    if (l != null) _send(l.window, l.range, l.zoom);
  }
}
