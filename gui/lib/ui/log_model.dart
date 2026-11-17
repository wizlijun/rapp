// The 日志 screen's state: which device, the filters, the rows and the 5-second top-up (log screen spec §4.2).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../hub_client.dart';
import '../log_view.dart';

typedef LogFetch = Future<LogPage> Function(String? id, LogQuery q);

const _sources = {'service', 'hub'};
const _limit = 200;
const _aroundLimit = 500;

class LogModel extends ChangeNotifier {
  LogModel({required this.fetch, Duration poll = const Duration(seconds: 5)}) : _every = poll;

  /// Asks a device's hub (null = 本机) for a page.
  final LogFetch fetch;
  final Duration _every;

  String? _device;
  bool _problemsOnly = true;
  LogKind? _kind;
  Set<String> _src = {..._sources};
  String _search = '';

  /// null = 本机.
  String? get device => _device;
  bool get problemsOnly => _problemsOnly;
  LogKind? get kind => _kind;
  Set<String> get sources => Set.unmodifiable(_src);
  String get search => _search;

  List<LogEntry> _rows = const [];
  bool _more = false;
  String? _older, _newer;
  Map<LogKind, int>? _counts;
  Map<LogKind, LogEntry>? _latest;
  List<String>? _launchd;
  String? _error;
  bool _loading = false;

  /// A poll or a quiet re-ask failed: no more polls until ⟳, the picker or a filter change (each failed
  /// request to an offline device writes 本机's hub.log).
  bool _halted = false;

  /// The ±1 min window, oldest first, while [aroundOf] is set.
  LogEntry? _aroundOf;
  List<LogEntry> _aroundRows = const [];
  String? _aroundError;

  /// New rows a poll brought while the list was scrolled down, newest first.
  List<LogEntry> _pending = const [];

  /// A first page fetched after a `gap` while scrolled down: shown when the user goes back to the top.
  LogPage? _held;
  bool _atTop = true;

  /// What is listed: the ±1 min window while it is open, else the timeline (newest first).
  List<LogEntry> get rows => _aroundOf != null ? _aroundRows : _rows;
  bool get more => _aroundOf == null && _more;
  Map<LogKind, int>? get counts => _counts;
  Map<LogKind, LogEntry>? get latest => _latest;
  List<String>? get launchd => _launchd;
  String? get error => _aroundOf != null ? _aroundError : _error;

  /// The first page is on its way.
  bool get loading => _loading;
  int get pendingNew => _pending.length;
  LogEntry? get aroundOf => _aroundOf;

  /// Bumped whenever the timeline is replaced as a whole (device, filter, ⟳): the list goes back to its top.
  int get resets => _resets;
  int _resets = 0;

  /// Every first page bumps it; a reply sent under an older value is dropped.
  int _gen = 0;
  Object? _olderToken, _pollToken, _aroundToken;
  Timer? _timer, _debounce;
  bool _disposed = false;

  /// Shows [device] (null = 本机) from its newest rows, then tops up every [poll].
  Future<void> open(String? device) {
    _device = device;
    _rows = const [];
    _pending = const [];
    _more = false;
    _older = _newer = null;
    _counts = _latest = null;
    _launchd = null;
    _error = null;
    _aroundOf = null;
    _aroundRows = const [];
    _aroundToken = null;
    _held = null;
    _timer?.cancel();
    _timer = Timer.periodic(_every, (_) => poll());
    return _first(quiet: false);
  }

  LogQuery _query({String? before, String? after}) => LogQuery(
        before: before,
        after: after,
        q: _search.isEmpty ? null : _search,
        problems: _problemsOnly,
        tailLaunchd: before == null && after == null,
        kind: _kind,
        src: _src.length == _sources.length ? null : {..._src},
        limit: _limit,
      );

  String _words(Object e) {
    final msg = e is HubException ? e.message : '$e';
    return msg.contains('unknown op') ? '对方版本太旧，看不到它的日志' : msg;
  }

  bool _stale(int gen, String? device) => _disposed || gen != _gen || device != _device;

  /// ⟳: the first page again, with the cards and the 启动输出; leaves the ±1 min window. Ignored while a first
  /// page is already on its way (each one costs the device a full read).
  Future<void> refresh() => _loading ? Future.value() : _first(quiet: false);

  /// [quiet]: asked by a poll (nothing listed yet, or a `gap`). No 读取中…, the list keeps its place, and a
  /// page that would replace rows the user has scrolled down to is held behind 「有 N 条新的」 instead.
  /// It does not bump [_gen]: a refresh or a device switch after it still makes its reply stale.
  Future<void> _first({required bool quiet}) async {
    final gen = quiet ? _gen : ++_gen;
    final device = _device;
    if (!quiet) {
      _olderToken = _pollToken = null;
      _halted = false;
      _held = null;
      _aroundOf = null;
      _aroundRows = const [];
      _aroundToken = null;
      _loading = true;
      _notify();
    }
    try {
      final p = await fetch(device, _query());
      if (_stale(gen, device)) return;
      _counts = p.counts;
      _latest = p.latest;
      _launchd = p.launchd;
      _error = null;
      if (quiet && !_atTop && _rows.isNotEmpty) {
        final seen = {for (final e in _rows) e.at};
        _held = p;
        _pending = [for (final e in _dedupe(p.events)) if (!seen.contains(e.at)) e];
      } else {
        _apply(p);
        if (!quiet) _resets++;
      }
    } catch (e) {
      if (_stale(gen, device)) return;
      _error = _words(e);
      _halted = true;
      if (!quiet) {
        _rows = const [];
        _pending = const [];
        _more = false;
        _older = _newer = null;
        _counts = _latest = null;
        _launchd = null;
        _resets++;
      }
    }
    if (!quiet) _loading = false;
    _notify();
  }

  void _apply(LogPage p) {
    // A loadOlder still out would append to the old rows' tail, leaving a hole under the new page.
    _olderToken = null;
    _rows = _dedupe(p.events);
    _pending = const [];
    _held = null;
    _atTop = true;
    _more = p.more;
    _older = p.older;
    _newer = p.newer;
  }

  /// The page before the oldest row shown.
  Future<void> loadOlder() async {
    if (!_more || _older == null || _olderToken != null || _aroundOf != null || _loading) return;
    final token = _olderToken = Object();
    final gen = _gen;
    final device = _device;
    try {
      final p = await fetch(device, _query(before: _older));
      if (_stale(gen, device) || _olderToken != token) return;
      final seen = {for (final e in _rows) e.at, for (final e in _pending) e.at};
      _rows = [..._rows, for (final e in p.events) if (seen.add(e.at)) e];
      _more = p.more;
      _older = p.older ?? _older;
      _notify();
    } catch (e) {
      if (_stale(gen, device) || _olderToken != token) return;
      _error = _words(e);
      _notify();
    } finally {
      if (_olderToken == token) _olderToken = null;
    }
  }

  /// Rows newer than the newest shown: on top when at the top, else held in [pendingNew]. One request a tick
  /// at most: a tick while one is in flight is skipped, and none after a failure ([_halted]).
  Future<void> poll() async {
    if (_aroundOf != null || _loading || _pollToken != null || _held != null || _halted || _disposed) return;
    final token = _pollToken = Object();
    try {
      if (_newer == null) {
        // No cursor (an empty log, or a gap): the first page again, quietly.
        await _first(quiet: true);
        return;
      }
      final gen = _gen;
      final device = _device;
      final p = await fetch(device, _query(after: _newer));
      if (_stale(gen, device) || _pollToken != token) return;
      // Rows were skipped: the next tick asks for the first page again, keeping the user's place.
      if (p.gap) {
        _newer = null;
        return;
      }
      _merge(p.events);
      _replace(p.again);
      _newer = p.newer ?? _newer;
      _error = null;
      _notify();
    } catch (e) {
      if (_disposed || _pollToken != token) return;
      _error = _words(e);
      _halted = true;
      _notify();
    } finally {
      if (_pollToken == token) _pollToken = null;
    }
  }

  /// A row already shown or held (same `at`) is replaced in place: its `repeat` may have grown.
  void _merge(List<LogEntry> events) {
    final rows = [..._rows];
    final pending = [..._pending];
    final rowAt = {for (var i = 0; i < rows.length; i++) rows[i].at: i};
    final pendingAt = {for (var i = 0; i < pending.length; i++) pending[i].at: i};
    final fresh = <LogEntry>[];
    final freshAt = <String>{};
    for (final e in events) {
      final r = rowAt[e.at], h = pendingAt[e.at];
      if (r != null) {
        rows[r] = e;
      } else if (h != null) {
        pending[h] = e;
      } else if (freshAt.add(e.at)) {
        fresh.add(e);
      }
    }
    _rows = rows;
    _pending = [...fresh, ...pending];
    if (_atTop) _flush();
  }

  /// `again`: a row shown or held whose `repeat` grew. One not listed (older than the rows loaded) stays out.
  void _replace(List<LogEntry> again) {
    if (again.isEmpty) return;
    final byAt = {for (final e in again) e.at: e};
    _rows = [for (final e in _rows) byAt[e.at] ?? e];
    _pending = [for (final e in _pending) byAt[e.at] ?? e];
  }

  void _flush() {
    // A gap page waiting behind the banner replaces the timeline as a whole.
    final held = _held;
    if (held != null) return _apply(held);
    if (_pending.isEmpty) return;
    _rows = [..._pending, ..._rows];
    _pending = const [];
  }

  static List<LogEntry> _dedupe(List<LogEntry> events) {
    final seen = <String>{};
    return [for (final e in events) if (seen.add(e.at)) e];
  }

  /// The list's scroll: away from the top, new rows wait in [pendingNew]; back at the top, they go in.
  void setAtTop(bool atTop) {
    if (_atTop == atTop) return;
    _atTop = atTop;
    if (atTop && (_pending.isNotEmpty || _held != null)) {
      _flush();
      _notify();
    }
  }

  /// 「有 N 条新的」: put the held rows on top (the list scrolls there).
  void showPending() {
    _atTop = true;
    _flush();
    _notify();
  }

  /// 看前后 ±1 分钟: every source and level within a minute of [e], oldest first.
  Future<void> around(LogEntry e) async {
    final token = _aroundToken = Object();
    final gen = _gen;
    final device = _device;
    _aroundOf = e;
    _aroundRows = const [];
    _aroundError = null;
    _notify();
    try {
      final p = await fetch(device, LogQuery(around: e.at, limit: _aroundLimit));
      if (_stale(gen, device) || _aroundToken != token) return;
      _aroundRows = _dedupe(p.events);
    } catch (err) {
      if (_stale(gen, device) || _aroundToken != token) return;
      _aroundError = _words(err);
    }
    _notify();
  }

  /// × on the ±1 min bar: back to the timeline as it was.
  void leaveAround() {
    if (_aroundOf == null) return;
    _aroundOf = null;
    _aroundRows = const [];
    _aroundToken = null;
    _aroundError = null;
    _notify();
  }

  void setProblemsOnly(bool v) {
    if (_problemsOnly == v) return;
    _problemsOnly = v;
    _first(quiet: false);
  }

  /// A card: only that kind; the same card again clears it.
  void toggleKind(LogKind k) {
    _kind = _kind == k ? null : k;
    _first(quiet: false);
  }

  /// A 来源 switch; the last one on stays on.
  void toggleSource(String s) {
    if (_src.contains(s)) {
      if (_src.length == 1) return;
      _src = {..._src}..remove(s);
    } else {
      _src = {..._src, s};
    }
    _first(quiet: false);
  }

  /// The search box: asks 300 ms after the last keystroke.
  void setSearch(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (q == _search) return;
      _search = q;
      _first(quiet: false);
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
