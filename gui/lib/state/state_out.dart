// What the app tells the rapp-state service on its own account (spec §8): the states it inferred for
// controlled devices, and its desk (what it has open). Event text (name, msg) is never logged.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'state_link.dart';

typedef AppReport = ({String state, String? kind, String? app, String name});

class _DeskMark {
  const _DeskMark();
}

class _Rep {
  _Rep(this.id, this.now, this.since);
  final String? id;
  final AppReport now;
  final int since;
}

class StateOut {
  StateOut({
    DateTime Function()? clock,
    String Function()? epoch,
    this.deskDelay = const Duration(seconds: 1),
    this.retry = const Duration(seconds: 5),
  }) : _clock = clock ?? DateTime.now,
       _epoch = (epoch ?? _randomEpoch)();

  static const maxPending = 200;

  final Duration deskDelay;
  final Duration retry;
  final DateTime Function() _clock;
  final String _epoch;

  String? _me;
  String? _meName;
  StateLink? _link;
  Map<String, Object?> _snapshot = const {};

  /// What the app reports now: device fp -> session -> report.
  final _current = <String, Map<String, _Rep>>{};
  List<Map<String, Object?>>? _desk;
  String? _deskSent;
  bool _deskOff = false;

  /// Events (maps) and desk marks, in the order they go out.
  final _queue = <Object>[];
  bool _sending = false;
  int _gen = 0;
  int _n = 0;
  Timer? _deskTimer;
  Timer? _retryTimer;

  bool get _ready => _link != null && _me != null;

  static String _randomEpoch() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  int _now() => _clock().millisecondsSinceEpoch ~/ 1000;

  void setMe(String? fp, String? device) {
    final changed = fp != _me;
    _me = fp;
    _meName = device;
    if (!changed) return;
    _gen++;
    _cancelTimers();
    _queue.clear();
    _sending = false;
    if (_ready) _resend();
  }

  /// [now] null means the session is gone. The same as last time sends nothing.
  void report({required String fp, String? id, required String session, required AppReport? now}) {
    final dev = _current[fp];
    final old = dev?[session];
    if (now == null) {
      if (old == null) return;
      dev!.remove(session);
      if (dev.isEmpty) _current.remove(fp);
      if (_ready) _push(_event('gone', fp, old.id, {'session': session}));
      return;
    }
    if (old != null && old.id == id && old.now == now) return;
    final since = old != null && old.now.state == now.state && old.now.kind == now.kind ? old.since : _now();
    final rep = _Rep(id ?? old?.id, now, since);
    _current.putIfAbsent(fp, () => {})[session] = rep;
    if (_ready) _push(_event('state', fp, rep.id, _fields(session, rep, since: false)));
  }

  void setDesk(List<Map<String, Object?>> sessions) {
    _desk = sessions;
    if (!_ready || _deskOff) return;
    _deskTimer?.cancel();
    _deskTimer = Timer(deskDelay, () {
      _deskTimer = null;
      if (!_ready || _deskOff || _queue.any((e) => e is _DeskMark)) return;
      if (jsonEncode(_desk) == _deskSent) return;
      _queue.add(const _DeskMark());
      _pump();
    });
  }

  /// Call once the service's picture is in place: [snapshot] is its `/v1/state`.
  void attach(StateLink link, Map<String, Object?> snapshot) {
    _gen++;
    _cancelTimers();
    _queue.clear();
    _sending = false;
    _link = link;
    _snapshot = snapshot;
    _deskOff = false;
    if (_ready) _resend();
  }

  void detach() {
    _gen++;
    _cancelTimers();
    _queue.clear();
    _sending = false;
    _link = null;
    _snapshot = const {};
  }

  void _cancelTimers() {
    _deskTimer?.cancel();
    _deskTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Map<String, Object?> _fields(String session, _Rep r, {required bool since}) => {
    'session': session,
    'name': r.now.name,
    'state': r.now.state,
    if (r.now.state == 'blocked' && r.now.kind != null) 'kind': r.now.kind,
    'app': ?r.now.app,
    if (since) 'since': r.since,
  };

  Map<String, Object?> _event(String t, String fp, String? id, Map<String, Object?> extra) => {
    'v': 1,
    't': t,
    'fp': fp,
    'id': ?id,
    'epoch': _epoch,
    'n': ++_n,
    'at': _now(),
    'src': 'app',
    'via': _me,
    ...extra,
  };

  /// The whole picture: a snap per device being reported, an empty one for a device the service still holds
  /// rows of ours for, then the desk.
  void _resend() {
    _queue.clear();
    final reporting = <String>{};
    _current.forEach((fp, sessions) {
      if (sessions.isEmpty) return;
      reporting.add(fp);
      final id = sessions.values.map((r) => r.id).whereType<String>().firstOrNull;
      _queue.add(_event('snap', fp, id, {
        'sessions': [for (final e in sessions.entries) _fields(e.key, e.value, since: true)],
      }));
    });
    final devices = _snapshot['devices'];
    if (devices is List) {
      for (final d in devices) {
        if (d is! Map || d['fp'] is! String || reporting.contains(d['fp'])) continue;
        final sessions = d['sessions'];
        final mine = sessions is List &&
            sessions.any((s) => s is Map && s['by'] == _me && s['src'] == 'app');
        if (!mine) continue;
        reporting.add(d['fp'] as String);
        _queue.add(_event('snap', d['fp'] as String, d['id'] is String ? d['id'] as String : null, {'sessions': []}));
      }
    }
    _deskSent = null;
    if (_desk != null && !_deskOff) _queue.add(const _DeskMark());
    _pump();
  }

  void _push(Map<String, Object?> event) {
    _queue.add(event);
    if (_queue.whereType<Map<String, Object?>>().length > maxPending) {
      _resend();
      return;
    }
    _pump();
  }

  Future<void> _pump() async {
    if (_sending || !_ready || _queue.isEmpty) return;
    _sending = true;
    final gen = _gen;
    final link = _link!;
    final me = _me!;
    try {
      while (_queue.isNotEmpty && gen == _gen) {
        if (_queue.first is _DeskMark) {
          _queue.removeAt(0);
          if (_deskOff || _desk == null) continue;
          final body = {'device': ?_meName, 'sessions': _desk};
          final sent = jsonEncode(_desk);
          try {
            await link.putDesk(me, body);
            if (gen == _gen) _deskSent = sent;
          } on StateLinkError catch (e) {
            if (e.status != 404) rethrow;
            if (gen == _gen) _deskOff = true;
          }
        } else {
          final batch = <Map<String, Object?>>[];
          while (_queue.isNotEmpty && _queue.first is Map<String, Object?>) {
            batch.add(_queue.removeAt(0) as Map<String, Object?>);
          }
          await link.postEvents(batch);
        }
      }
    } catch (_) {
      if (gen == _gen) {
        _queue.clear();
        _retryTimer?.cancel();
        _retryTimer = Timer(retry, () {
          _retryTimer = null;
          if (_ready) _resend();
        });
      }
    } finally {
      if (gen == _gen) {
        _sending = false;
        if (_queue.isNotEmpty) _pump();
      }
    }
  }
}
