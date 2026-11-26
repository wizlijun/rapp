// Finds, connects to and follows the rapp-state service (`services/state/api/http.md`).
// Only status changes are logged; event text (msg, title, name) never is.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'state_config.dart';
import 'state_link.dart';

enum StateStatus { off, none, connecting, connected, unreachable }

typedef Row = Map<String, Object?>;

class StateSync extends ChangeNotifier {
  /// [clock] is accepted for the callers' symmetry with other stores; row times come from the service, so it is unused.
  StateSync({
    required this.localDir,
    required this.find,
    StateLink Function(Uri)? link,
    DateTime Function()? clock,
  }) : _makeLink = link ?? StateLink.new,
       config = StateConfig.load(localDir);

  static const maxRows = 200;
  static const maxPending = 200;
  static const _backoff = [2, 4, 8, 16, 32, 60];

  final String localDir;
  final Future<String?> Function() find;
  final StateLink Function(Uri) _makeLink;

  StateConfig config;
  StateStatus status = StateStatus.off;
  Uri? url;
  List<Row> rows = [];
  List<Row> needs = [];
  int outage = 0;

  List<Row> _devices = [];
  final _pending = <(String fp, String session)>[];
  StateLink? _link;
  StreamSubscription<Row>? _sub;
  Timer? _timer;
  int _gen = 0;
  int _attempt = 0;
  bool _started = false;
  bool _disposed = false;
  bool _flushing = false;

  Row? session(String fp, String id) {
    for (final d in _devices) {
      if (d['fp'] != fp) continue;
      for (final s in _sessions(d)) {
        if (s['session'] == id) return s;
      }
    }
    return null;
  }

  String? fpOf(String deviceId) {
    for (final d in _devices) {
      if (d['id'] == deviceId) return d['fp'] as String?;
    }
    return null;
  }

  String? idOf(String fp) {
    for (final d in _devices) {
      if (d['fp'] == fp) return d['id'] as String?;
    }
    return null;
  }

  bool fresh(Row row) {
    final s = session('${row['fp']}', '${row['session']}');
    if (s == null) return false;
    final at = row['at'];
    final seen = s['seen'];
    return at is num && at > (seen is num ? seen : 0);
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _connect();
  }

  Future<void> setConfig(StateConfig c) {
    config = c;
    c.save(localDir);
    return _connect();
  }

  Future<void> refresh() => _connect();

  void pause() {
    _gen++;
    _cancelAll();
  }

  void markSeen(String deviceId, String session) {
    final fp = fpOf(deviceId);
    if (fp == null) return;
    _pending.add((fp, session));
    if (_pending.length > maxPending) _pending.removeAt(0);
    if (status == StateStatus.connected) _flush();
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _cancelAll();
    super.dispose();
  }

  void _cancelAll() {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
    _link?.close();
    _link = null;
  }

  void _set(StateStatus s) {
    if (_disposed) return;
    if (s == StateStatus.unreachable && status != StateStatus.unreachable) outage++;
    if (s != status) debugPrint('state_sync: ${s.name}');
    status = s;
    notifyListeners();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final gen = ++_gen;
    _cancelAll();
    bool stale() => _disposed || gen != _gen;

    if (config.mode == StateMode.off) {
      url = null;
      return _set(StateStatus.off);
    }
    String? found;
    if (config.mode == StateMode.manual) {
      found = config.url;
    } else {
      try {
        found = await find();
      } catch (_) {
        found = null;
      }
      if (stale()) return;
    }
    final uri = found == null || StateConfig.checkUrl(found) != null ? null : Uri.parse(found.trim());
    if (uri == null) {
      url = null;
      _set(StateStatus.none);
      // A manual address that does not parse stays none until the user fixes it; auto looks again.
      if (config.mode == StateMode.auto) _timer = Timer(const Duration(seconds: 60), _connect);
      return;
    }
    url = uri;
    // A retry keeps showing unreachable, so one outage counts once however many retries it takes.
    if (status != StateStatus.unreachable) _set(StateStatus.connecting);
    final link = _link = _makeLink(uri);
    try {
      if (!await link.health()) return _fail(gen);
      if (stale()) return;
      final st = await link.state();
      final page = await link.queue(limit: 50);
      if (stale()) return;
      _applyState(st);
      _applyPage(page);
    } catch (_) {
      return _fail(gen);
    }
    _sub = link.watch().listen(
      (e) => _onPush(gen, e),
      onError: (Object _) => _fail(gen),
      onDone: () => _fail(gen),
      cancelOnError: true,
    );
    notifyListeners();
  }

  void _fail(int gen) {
    if (_disposed || gen != _gen) return;
    _sub?.cancel();
    _sub = null;
    _link?.close();
    _link = null;
    _set(StateStatus.unreachable);
    final secs = _backoff[_attempt < _backoff.length ? _attempt : _backoff.length - 1];
    _attempt++;
    _timer = Timer(Duration(seconds: secs), _connect);
  }

  List<Row> _sessions(Row device) {
    final s = device['sessions'];
    return s is List ? s.whereType<Row>().toList() : const [];
  }

  void _applyState(Row st) {
    final d = st['devices'];
    _devices = [
      if (d is List)
        for (final x in d)
          if (x is Row) {...x, 'sessions': _sessions(x).map((s) => {...s}).toList()},
    ];
    final n = st['needs'];
    needs = n is List ? n.whereType<Row>().toList() : [];
  }

  void _applyPage(Row page) {
    final e = page['events'];
    final events = e is List ? e.whereType<Row>().toList() : <Row>[];
    if (events.isEmpty) return;
    var oldest = _at(events.first);
    for (final r in events) {
      if (_at(r) < oldest) oldest = _at(r);
    }
    rows = _dedupe([...events, ...rows.where((r) => _at(r) < oldest)]);
  }

  num _at(Row r) => r['at'] is num ? r['at'] as num : 0;

  List<Row> _dedupe(List<Row> list) {
    final seen = <Object?>{};
    final out = <Row>[];
    for (final r in list) {
      if (seen.add(r['eid'])) out.add(r);
      if (out.length >= maxRows) break;
    }
    return out;
  }

  void _onPush(int gen, Row e) {
    if (_disposed || gen != _gen) return;
    switch (e['what']) {
      case 'hello':
        _attempt = 0;
        _set(StateStatus.connected);
        _flush();
        return;
      case 'session':
        _onSession(e);
      case 'queue':
        final r = e['row'];
        if (r is Row) rows = _dedupe([if (!rows.any((x) => x['eid'] == r['eid'])) r, ...rows]);
      case 'need':
        final n = e['needs'];
        if (n is List) needs = n.whereType<Row>().toList();
      case 'seen':
        _onSeen(e);
      default:
        return;
    }
    notifyListeners();
  }

  void _onSession(Row e) {
    final fp = e['fp'];
    final id = e['session'];
    final row = e['row'];
    for (final d in _devices) {
      if (d['fp'] != fp) continue;
      final list = _sessions(d)..removeWhere((s) => s['session'] == id);
      if (row is Row) list.add({...row});
      d['sessions'] = list;
    }
  }

  void _onSeen(Row e) {
    final at = e['at'];
    if (e['eid'] != null) {
      for (final r in rows) {
        if (r['eid'] == e['eid']) {
          r['seen'] = at;
          if (e['handled'] == true) r['handled'] = true;
        }
      }
      return;
    }
    final s = session('${e['fp']}', '${e['session']}');
    if (s != null) s['seen'] = at;
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty && status == StateStatus.connected && !_disposed) {
        final link = _link;
        if (link == null) return;
        final item = _pending.removeAt(0);
        try {
          await link.seen(fp: item.$1, session: item.$2);
        } on StateLinkError catch (e) {
          if (e.status == 0) _pending.insert(0, item);
          if (e.status == 0) return;
        } catch (_) {
          return;
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
