// Finds, connects to and follows the center service (rapp-center) (`services/center/api/http.md`).
// Only status changes are logged; event text (msg, title, name) never is.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../quick/quick_sync.dart';
import 'state_config.dart';
import 'state_link.dart';
import 'state_out.dart';

enum StateStatus { off, none, connecting, connected, unreachable }

typedef Row = Map<String, Object?>;

class StateSync extends ChangeNotifier {
  /// [clock] is accepted for the callers' symmetry with other stores; row times come from the service, so it is unused.
  StateSync({
    required this.localDir,
    required this.find,
    StateLink Function(Uri)? link,
    DateTime Function()? clock,
    StateOut? out,
    this.quick,
  }) : out = out ?? StateOut(),
       _makeLink = link ?? StateLink.new,
       config = StateConfig.load(localDir);

  static const maxRows = 200;
  static const maxPending = 200;
  static const _backoff = [2, 4, 8, 16, 32, 60];

  final String localDir;
  final Future<String?> Function() find;
  final StateLink Function(Uri) _makeLink;

  /// The 快捷区 settings sync: attached to each link that comes up, told when the service goes away or sends `prefs.*`.
  final QuickSync? quick;

  /// The app's own reports and desk upload; attached while connected.
  final StateOut out;

  StateConfig config;
  StateStatus status = StateStatus.off;
  Uri? url;
  List<Row> rows = [];
  List<Row> needs = [];
  int outage = 0;

  /// Whether [rows], [needs] and the sessions are a snapshot of the service the app may keep showing: true from
  /// the first hello on, still true while a [refresh] reconnects, false once the service is unreachable, found
  /// nothing, is off, or a new config points elsewhere.
  bool hasSnapshot = false;

  List<Row> _devices = [];
  Map<String, Row> _desks = {};

  /// Whether the last `/v1/state` had a `desks` key: a P2 service (0.15.48–0.15.51) has none, and [out] then
  /// sends it nothing.
  bool _hasDesks = false;

  /// Every app's desk by fingerprint, sorted by fp.
  List<Row> get desks => [for (final k in _desks.keys.toList()..sort()) _desks[k]!];

  /// "Seen" marks not sent yet, by device id; the fp is looked up when they go out (spec §9.3).
  final _pending = <(String deviceId, String session)>[];
  StateLink? _link;
  StreamSubscription<Row>? _sub;
  Timer? _timer;

  /// A coming `/v1/state` fetch for a pushed device the app could not place (an older service's push).
  Timer? _refetch;

  /// Pushes that came while the snapshot was being fetched; null while they apply at once.
  List<Row>? _buffer;

  /// A [refresh] of a working link: its first failed try is retried in 2 s without going unreachable.
  bool _grace = false;

  /// Whether a `/v1/state` was applied since the last config change.
  bool _known = false;
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
    // Another service, or none: what the old one said is not shown again.
    _drop();
    return _connect();
  }

  /// Reconnects and fetches everything again (back in the foreground). From a working link the last snapshot
  /// stays on show meanwhile, and one failed try is not yet an outage.
  Future<void> refresh() {
    _grace = status == StateStatus.connected || (status == StateStatus.connecting && hasSnapshot);
    return _connect();
  }

  void pause() {
    _gen++;
    _cancelAll();
  }

  /// Tells the service [session] on [deviceId] was looked at. Kept (at most [maxPending], oldest dropped) until
  /// connected. Once the app knows the service's devices, a device it does not list is dropped at once.
  void markSeen(String deviceId, String session) {
    if (_known && fpOf(deviceId) == null && _refetch == null) return;
    _pending
      ..removeWhere((p) => p.$1 == deviceId && p.$2 == session)
      ..add((deviceId, session));
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
    out.detach();
    _timer?.cancel();
    _timer = null;
    _refetch?.cancel();
    _refetch = null;
    _buffer = null;
    _sub?.cancel();
    _sub = null;
    _link?.close();
    _link = null;
  }

  /// Forgets everything the service said.
  void _drop() {
    hasSnapshot = false;
    _known = false;
    _devices = [];
    _desks = {};
    rows = [];
    needs = [];
  }

  void _set(StateStatus s) {
    if (_disposed) return;
    if (s == StateStatus.off || s == StateStatus.none) _drop();
    // Unreachable keeps the rows for the next page merge but stops showing them.
    if (s == StateStatus.unreachable) hasSnapshot = false;
    if (s == StateStatus.unreachable && status != StateStatus.unreachable) outage++;
    if (s == StateStatus.off || s == StateStatus.none) quick?.detach(reachable: true);
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
    } catch (_) {
      return _fail(gen);
    }
    if (stale()) return;
    // The watch opens first and its pushes wait while the snapshot is fetched (on hello), so nothing that
    // changes in between is lost.
    _buffer = [];
    _sub = link.watch().listen(
      (e) => _onPush(gen, e),
      onError: (Object _) => _fail(gen),
      onDone: () => _fail(gen),
      cancelOnError: true,
    );
  }

  /// The watch said hello: fetch the snapshot, apply it, then the pushes that came meanwhile, in order.
  Future<void> _onHello(int gen) async {
    final link = _link;
    if (link == null) return;
    _buffer ??= [];
    try {
      final st = await link.state();
      final page = await link.queue(limit: 50);
      if (_disposed || gen != _gen) return;
      _applyState(st);
      _applyPage(page);
    } catch (_) {
      return _fail(gen);
    }
    final held = _buffer ?? const <Row>[];
    _buffer = null;
    for (final e in held) {
      _apply(e);
    }
    hasSnapshot = true;
    _attempt = 0;
    _grace = false;
    _set(StateStatus.connected);
    _attachOut(link);
    _flush();
    final q = quick;
    if (q != null) {
      if (link.prefs) {
        unawaited(q.attach(link));
      } else {
        q.detach(reachable: true);
      }
    }
  }

  void _attachOut(StateLink link) => out.attach(link, {'devices': _devices, if (_hasDesks) 'desks': desks});

  void _fail(int gen) {
    if (_disposed || gen != _gen) return;
    // Later failures of this same try (the watch and a fetch both failing) are not new ones.
    _gen++;
    _cancelAll();
    quick?.detach(reachable: false);
    if (_grace) {
      // The first failed try after a refresh of a working link: keep showing what it had, try again soon.
      _grace = false;
      _timer = Timer(Duration(seconds: _backoff.first), _connect);
      return;
    }
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
    _known = true;
    final d = st['devices'];
    _devices = [
      if (d is List)
        for (final x in d)
          if (x is Row) {...x, 'sessions': _sessions(x).map((s) => {...s}).toList()},
    ];
    final ds = st['desks'];
    _hasDesks = st.containsKey('desks');
    _desks = {
      if (ds is List)
        for (final x in ds)
          if (x is Row && x['fp'] is String) x['fp'] as String: x,
    };
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
    if (e['what'] == 'hello') {
      _onHello(gen);
      return;
    }
    final held = _buffer;
    if (held != null) {
      held.add(e);
      return;
    }
    if (_apply(e)) notifyListeners();
  }

  /// Applies one push; false for one the app does not know.
  bool _apply(Row e) {
    switch (e['what']) {
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
      case 'desk':
        final fp = e['fp'];
        final d = e['desk'];
        if (fp is String) {
          if (d is Row) {
            _desks[fp] = {'fp': fp, ...d};
          } else {
            _desks.remove(fp);
          }
        }
      default:
        final w = e['what'];
        if (w is String && w.startsWith('prefs.')) quick?.onPush(e);
        return false;
    }
    return true;
  }

  void _onSession(Row e) {
    final fp = e['fp'];
    final id = e['session'];
    final row = e['row'];
    if (fp is! String) return;
    var dev = _devices.where((d) => d['fp'] == fp).firstOrNull;
    if (dev == null) {
      if (row is! Row) return;
      final devId = e['id'];
      if (devId is! String) {
        // An older service names no device in its push: look at the whole state again, once for a burst.
        _refetchSoon();
        return;
      }
      dev = {'fp': fp, 'id': devId, 'device': ?e['device'], 'sessions': <Row>[]};
      _devices.add(dev);
    } else {
      for (final k in ['id', 'device']) {
        if (e[k] is String) dev[k] = e[k];
      }
    }
    final list = _sessions(dev)..removeWhere((s) => s['session'] == id);
    if (row is Row) list.add({...row});
    dev['sessions'] = list;
  }

  void _refetchSoon() {
    if (_refetch != null) return;
    final gen = _gen;
    _refetch = Timer(const Duration(seconds: 1), () async {
      final link = _link;
      try {
        if (link == null) return;
        final st = await link.state();
        if (_disposed || gen != _gen) return;
        _applyState(st);
        _attachOut(link);
        notifyListeners();
      } catch (_) {
        // The watch notices a dead link itself; a failed look leaves things as they were.
      } finally {
        if (gen == _gen) _refetch = null;
      }
      if (!_disposed && gen == _gen) _flush();
    });
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

  /// Sends the kept marks in order, one PUT per session however many marks it has. A mark whose device the
  /// service does not list is dropped, unless a fetch that may bring it is coming.
  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    final sent = <String>{};
    try {
      var i = 0;
      while (i < _pending.length && status == StateStatus.connected && !_disposed) {
        final link = _link;
        if (link == null) return;
        final item = _pending[i];
        final fp = fpOf(item.$1);
        if (fp == null) {
          if (_refetch != null) {
            i++;
          } else {
            _pending.removeAt(i);
          }
          continue;
        }
        _pending.removeAt(i);
        if (!sent.add('$fp\n${item.$2}')) continue;
        try {
          await link.seen(fp: fp, session: item.$2);
        } on StateLinkError catch (e) {
          if (e.status == 0) {
            _pending.insert(i, item);
            return;
          }
        } catch (_) {
          return;
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
