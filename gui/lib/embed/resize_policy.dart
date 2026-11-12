// When the stage's size should become A's window size (R12).
import 'dart:async';
import 'dart:ui';

import 'geometry.dart';
import 'session_port.dart';

class ResizePolicy {
  ResizePolicy(this._send);
  final void Function(int window, int w, int h) _send;

  Size? _stage;
  RemoteWindow? _win;
  Timer? _timer;

  /// The stage changed size: judge once it has been still for 0.3 s.
  void stage(Size s) {
    if (s == _stage) return;
    _stage = s;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), _judge);
  }

  /// The current window; a different id is judged at once, later updates of the same window
  /// (A's own size) only refresh what is known about it.
  void current(RemoteWindow? w) {
    final changed = w?.id != _win?.id;
    _win = w;
    if (!changed) return;
    _timer?.cancel();
    if (w != null) _judge();
  }

  void _judge() {
    final s = _stage, w = _win;
    if (s == null || w == null || !w.resizable) return;
    final c = contentSize(w);
    final sw = s.width.round(), sh = s.height.round();
    if (sw == c.width.round() && sh == c.height.round()) return;
    _send(w.id, sw, sh);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
