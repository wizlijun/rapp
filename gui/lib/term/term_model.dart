import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'sgr.dart';
import 'term_wire.dart';

/// History lines asked for per request.
const int historyBatch = 500;

/// After a failed history read, how long until history is asked for again.
const Duration historyRetryAfter = Duration(seconds: 3);

/// The grid of one terminal pane: the screen, the local scrollback and the scroll position (design H1, H2).
///
/// Row coordinate y: y >= 0 is screen row y; y < 0 is history, -1 being the line right above the screen.
class TermModel extends ChangeNotifier {
  TermModel({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// The pane being watched; screens of other panes are only acked.
  String? pane;
  int cols = 0, rows = 0, cx = 0, cy = 0;
  bool cursor = false, alt = false;
  String shape = '';

  /// History size and limit on the device as of the latest screen; null on old devices.
  int? hist, limit;

  /// Rows scrolled up from the bottom; 0 = latest.
  double offset = 0;

  /// Output arrived while reading history.
  bool newOutput = false;

  /// The oldest history line has been fetched.
  bool historyTop = false;

  /// The device's latest error text (shown on the stage for 3 seconds).
  String? note;

  /// Lines moved into history (the selection follows, task 8).
  void Function(int d)? onShift;

  List<String> _raw = const [];
  List<TermLine> _screen = const [];
  Set<int> _wrapped = const {};

  // Index 0 is the line right above the screen (y = -1). Null: not fetched yet.
  final List<TermLine?> _hist = [];
  // _histWrap[i]: the line below history line i continues it.
  final List<bool> _histWrap = [];

  List<String>? _pending;
  int _pendingRev = 0;
  bool _inFlight = false;
  bool _dropNext = false;
  // A history read failed: none is asked for before this.
  DateTime? _retryAt;

  List<TermLine> get screen => _screen;

  /// The stage sent `view`: only this pane's screens are used from now on. Also sent again for a new size of the
  /// same pane, so any history request in flight is given up even for the same pane.
  void expect(String pane) {
    if (pane != this.pane) {
      this.pane = pane;
      _pending = null;
      _raw = const [];
      _screen = const [];
      _wrapped = const {};
      _clearHistory();
      _retryAt = null;
    }
    _inFlight = false;
    _dropNext = false;
    notifyListeners();
  }

  /// One part of a screen update. Returns the rev to ack for the last part (`more == false`), otherwise null.
  int? apply(TermScreen m) {
    final ack = m.more ? null : m.rev;
    if (pane == null || m.pane != pane) return ack;
    var rows = _pending;
    if (rows == null || _pendingRev != m.rev) {
      rows = m.full ? List.filled(m.rows, '') : [for (var i = 0; i < m.rows; i++) i < _raw.length ? _raw[i] : ''];
      _pending = rows;
      _pendingRev = m.rev;
    }
    for (final (i, s) in m.lines) {
      if (i >= 0 && i < rows.length) rows[i] = s;
    }
    if (!m.more) {
      _pending = null;
      _commit(m, rows);
    }
    return ack;
  }

  void _commit(TermScreen m, List<String> raw) {
    final oldRaw = _raw;
    final old = _screen;
    final oldWrapped = _wrapped;
    final had = old.isNotEmpty;
    final resized = had && (m.cols != cols || m.rows != rows);
    final reuse = <String, TermLine>{for (var i = 0; i < oldRaw.length; i++) oldRaw[i]: old[i]};
    final next = [for (final s in raw) reuse[s] ?? parseRow(s)];
    var changed = raw.length != oldRaw.length;
    for (var i = 0; !changed && i < raw.length; i++) {
      changed = raw[i] != oldRaw[i];
    }
    final wasReading = offset > 0;

    var d = 0;
    if (resized) {
      _clearHistory();
    } else if (had && !alt && !m.alt) {
      final oh = hist, nh = m.hist;
      if (oh == null && nh == null) {
        // Old device: only the overlap tells.
        d = _overlap(old, next);
      } else if (oh != null && nh != null) {
        final grown = nh > oh ? nh - oh : 0;
        // At the limit the count stops growing (or grows less than the scroll): the overlap tells the rest.
        final atLimit = nh == m.limit && (oh == limit || grown > 0);
        d = atLimit ? math.max(grown, _overlap(old, next)) : grown;
      }
    }
    if (d > 0) {
      // Old rows d-1..0 land at history 0..d-1 when the new screen lines up with the old one shifted by d.
      final fits = d < rows && _linesUp(old, next, d);
      _hist.insertAll(0, [for (var i = 0; i < d; i++) fits ? old[d - 1 - i] : null]);
      _histWrap.insertAll(0, [for (var i = 0; i < d; i++) fits && oldWrapped.contains(d - 1 - i)]);
    }

    cols = m.cols;
    rows = m.rows;
    cx = m.cx;
    cy = m.cy;
    cursor = m.cursor;
    alt = m.alt;
    shape = m.shape;
    hist = m.hist;
    limit = m.limit;
    _raw = raw;
    _screen = next;
    _wrapped = m.wrapped;

    final h = hist;
    if (h != null && _hist.length > h) {
      _hist.length = h;
      _histWrap.length = h;
    }
    if (h != null && _hist.length < h) historyTop = false;
    if (wasReading) {
      offset = (offset + d).clamp(0, scrollMax).toDouble();
      if (changed) newOutput = true;
    }
    if (offset == 0) newOutput = false;
    if (d > 0) onShift?.call(d);
    notifyListeners();
  }

  /// The smallest k (1 <= k < rows) with new rows 0..rows-k-1 equal to old rows k..rows-1 and not all blank; 0 if none.
  int _overlap(List<TermLine> old, List<TermLine> next) {
    final n = old.length;
    if (next.length != n) return 0;
    for (var k = 1; k < n; k++) {
      if (!_linesUp(old, next, k)) continue;
      for (var i = 0; i < n - k; i++) {
        if (next[i].text.trim().isNotEmpty) return k;
      }
    }
    return 0;
  }

  static bool _linesUp(List<TermLine> old, List<TermLine> next, int k) {
    final n = old.length;
    if (next.length != n) return false;
    for (var i = 0; i < n - k; i++) {
      if (next[i].text != old[i + k].text) return false;
    }
    return true;
  }

  void _clearHistory() {
    _hist.clear();
    _histWrap.clear();
    offset = 0;
    newOutput = false;
    historyTop = false;
    // A reply still on its way was cut for the old history: drop it.
    if (_inFlight) _dropNext = true;
  }

  /// Shows [text] on the stage as its note.
  void say(String text) {
    note = text;
    notifyListeners();
  }

  /// The device answered with an `error` (a failed history read comes back this way, not as `history`). With a
  /// history request in flight it is taken as that request's answer: it ends, and the next one waits
  /// [historyRetryAfter] so a read that keeps failing is not asked again at once.
  void fail(String error) {
    note = error;
    if (_inFlight) {
      _inFlight = false;
      _dropNext = false;
      _retryAt = _clock().add(historyRetryAfter);
    }
    notifyListeners();
  }

  void applyHistory(TermHistory m) {
    // Another pane's reply answers no request of this one's.
    if (pane == null || m.pane != pane) return;
    final drop = _dropNext;
    _inFlight = false;
    _dropNext = false;
    if (drop) return;
    _retryAt = null;
    final mh = m.hist, h = hist;
    final adj = mh != null && h != null ? h - mh : 0;
    final len = m.lines.length;
    for (var k = 0; k < len; k++) {
      final i = m.before + adj + (len - 1 - k);
      if (i < 0) continue;
      while (_hist.length <= i) {
        _hist.add(null);
        _histWrap.add(false);
      }
      _hist[i] = parseRow(m.lines[k]);
      _histWrap[i] = k + 1 < len && m.wrapped.contains(k);
    }
    if (len == 0 || (h != null && _hist.length >= h)) historyTop = true;
    notifyListeners();
  }

  /// The next batch to fetch, marked in flight; null when nothing is needed, a request is already in flight, or a
  /// failed one is still waiting out [historyRetryAfter].
  ({int before, int lines})? wantHistory() {
    if (_inFlight || pane == null || _screen.isEmpty) return null;
    final retry = _retryAt;
    if (retry != null) {
      if (_clock().isBefore(retry)) return null;
      _retryAt = null;
    }
    // An unknown line in view first: from the one nearest the screen, the run of unknown lines.
    final lo = (offset.floor() - rows).clamp(0, _hist.length);
    final hi = offset.ceil().clamp(0, _hist.length);
    for (var i = lo; i < hi; i++) {
      if (_hist[i] != null) continue;
      var n = 0;
      while (i + n < _hist.length && _hist[i + n] == null && n < historyBatch) {
        n++;
      }
      _inFlight = true;
      return (before: i, lines: n);
    }
    final h = hist;
    if (!historyTop && (h == null || _hist.length < h) && _hist.length < offset + rows) {
      _inFlight = true;
      return (before: _hist.length, lines: historyBatch);
    }
    return null;
  }

  /// Null for history not fetched yet.
  TermLine? lineAt(int y) {
    if (y >= 0) return y < _screen.length ? _screen[y] : null;
    final i = -1 - y;
    return i < _hist.length ? _hist[i] : null;
  }

  /// Whether line y + 1 continues line y.
  bool wrappedAt(int y) {
    if (y >= 0) return _wrapped.contains(y);
    final i = -1 - y;
    return i < _histWrap.length && _histWrap[i];
  }

  /// Rows one can scroll up: `hist`; old devices: the known history, plus 1 until the top.
  int get scrollMax => hist ?? _hist.length + (historyTop ? 0 : 1);

  void scrollBy(double rows) {
    offset = (offset + rows).clamp(0, scrollMax).toDouble();
    if (offset == 0) newOutput = false;
    notifyListeners();
  }

  void toBottom() {
    offset = 0;
    newOutput = false;
    notifyListeners();
  }
}
