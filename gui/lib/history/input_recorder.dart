// The input record (spec 2026-11-14-rapp-input-history §4): every piece the writing panel sends,
// and every draft left unsent, as one JSON line; the drafts themselves wait in `local/drafts/`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../embed/app_profile.dart';
import '../embed/composer_model.dart';
import '../embed/remote_session.dart';
import '../paths.dart';
import 'draft_store.dart';
import 'input_log.dart';
import 'record_id.dart';

/// What a record says about the session it came from, taken at the moment it is written.
class SessionMeta {
  SessionMeta({
    required this.key,
    required this.hostId,
    required this.hostName,
    required this.appId,
    required this.appName,
    required this.run,
    this.windowId,
    this.windowTitle,
    List<String>? projects,
  }) : projects = projects ?? [];

  String key;
  String hostId, hostName;
  String appId, appName;
  String run;
  int? windowId;
  String? windowTitle;
  List<String> projects;

  Map<String, Object?> toJson() => {
        'key': key,
        'hostId': hostId,
        'hostName': hostName,
        'appId': appId,
        'appName': appName,
        'run': run,
        if (windowId != null) 'windowId': windowId,
        if (windowTitle != null) 'windowTitle': windowTitle,
        'projects': projects,
      };

  /// Back from a draft file's `meta`; what is missing comes from [key] (`<host>/<app>`) or is empty.
  static SessionMeta fromJson(String key, Map<String, Object?> j) {
    String s(String k, String or) => j[k] is String ? j[k] as String : or;
    final cut = key.indexOf('/');
    final ps = j['projects'];
    final w = j['windowId'];
    return SessionMeta(
      key: s('key', key),
      hostId: s('hostId', cut < 0 ? key : key.substring(0, cut)),
      hostName: s('hostName', ''),
      appId: s('appId', cut < 0 ? '' : key.substring(cut + 1)),
      appName: s('appName', ''),
      run: s('run', ''),
      windowId: w is int ? w : null,
      windowTitle: j['windowTitle'] is String ? j['windowTitle'] as String : null,
      projects: ps is List ? [for (final p in ps) if (p is String) p] : [],
    );
  }
}

/// A sent piece whose round has not finished: its text stays in the draft file until then, and a
/// crash meanwhile brings it back.
class _Piece {
  _Piece(this.text, this.owner, this.rs);
  final String text;

  /// The send it is (an adopted row after a swap); null for one read back from a file, or whose
  /// session went with no other to take it.
  Outgoing? owner;
  RemoteSession? rs;

  /// Its record is being written: a draft record made meanwhile leaves it out.
  bool finishing = false;
}

/// One session key's draft as the file holds it.
class _Draft {
  _Draft(this.key);
  final String key;
  String text = '';
  final pieces = <_Piece>[];

  /// Records of finished rounds whose write failed, oldest first: appended by a later write.
  final stored = <Map<String, Object?>>[];
  Map<String, Object?> meta = {};

  /// Rounds whose record is being written.
  final busy = <Future<void>>{};

  /// The last append of [stored] (one at a time).
  Future<bool> flushing = Future.value(true);
}

class InputRecorder {
  /// [enabled]: the overall switch (`gui.json` `inputHistory`); each session's app has its own.
  InputRecorder(
      {required this.data,
      required this.enabled,
      this.recordsApp,
      void Function(String)? log,
      DateTime Function()? clock})
      : _log = log ?? ((_) {}),
        _clock = clock ?? DateTime.now {
    _store = DraftStore(() => data().draftsDir);
    _input = InputLog(() => _inputsDir);
  }

  final DataDir Function() data;
  final bool Function() enabled;

  /// The app's switch (`recordInput`) as it is now; asked for drafts nobody has open. Null: the
  /// switch saved in the draft file decides. An app the profiles do not know resolves to the
  /// default (on), so the saved switch still has to be on as well.
  final bool Function(String appId)? recordsApp;
  final void Function(String) _log;
  final DateTime Function() _clock;
  late final DraftStore _store;
  late final InputLog _input;
  String _inputsDir = '';
  final _written = StreamController<Map<String, Object?>>.broadcast();
  final Map<String, _Draft> _drafts = {};
  final Map<RemoteSession, ({String key, SessionMeta Function() meta})> _attached = {};

  /// What each send's record says of its session: taken when it was handed off.
  final _handed = Expando<SessionMeta>();

  /// A failure was said and no write has gone since.
  bool _failSaid = false;

  /// Every record, once it is written.
  Stream<Map<String, Object?>> get written => _written.stream;

  /// Follows [rs]'s composer from now on. [restore]: a new open (no older session hands its
  /// text over), so the unfinished pieces and the text go back into the composer; records left
  /// unwritten are appended, never put back.
  void attach(RemoteSession rs, SessionMeta Function() meta, {required bool restore}) {
    final m = meta();
    final d = _drafts[m.key] ??= _load(m.key);
    _attached[rs] = (key: m.key, meta: meta);
    final c = rs.composer;
    final back = [for (final p in d.pieces) if (p.owner == null && !p.finishing) p];
    if (restore && (back.isNotEmpty || d.text.isNotEmpty)) {
      final t = _join([for (final p in back) p.text], d.text);
      d.pieces.removeWhere(back.contains);
      d.text = t;
      c.setDraft(t);
      _save(d, rs);
    }
    c.onDraftChanged = (t) {
      d.text = t;
      // A row put back is in the editor text now: not pending as well. (Not while the text is
      // cleared: a submit asks before the composer marks its row in flight.)
      if (t.isNotEmpty) d.pieces.removeWhere(_wentBack);
      _save(d, rs);
    };
    c.onSubmitted = (o) {
      _handed[o] = meta();
      if (o.text.isEmpty) return;
      // An adopted row's retry: its text is pending once already.
      final p = d.pieces.where((p) => identical(p.owner, o)).firstOrNull;
      if (p != null) {
        p.rs = rs;
        return;
      }
      d.pieces.add(_Piece(o.text, o, rs));
      _save(d, rs);
    };
    c.onFinished = (o, {required all}) {
      final f = _finished(d, rs, o, all);
      d.busy.add(f);
      unawaited(f.whenComplete(() => d.busy.remove(f)));
    };
    if (d.stored.isNotEmpty && enabled() && rs.recordsInput) unawaited(_flush(d));
  }

  /// [rs] went for good. [to] goes on with its session (a reconnect's or a move's swap) and
  /// [moved] is what its `adoptFrom` made of [rs]'s rows: an unfinished piece follows its row
  /// there, so a retry of that row finds it. Without one it stays pending with no session, and
  /// the next open brings it back.
  void detach(RemoteSession rs, {RemoteSession? to, Map<Outgoing, Outgoing>? moved}) {
    final a = _attached.remove(rs);
    if (a == null) return;
    _unhook(rs);
    final d = _drafts[a.key];
    if (d == null) return;
    var dropped = false;
    for (final p in [...d.pieces]) {
      if (!identical(p.rs, rs) || p.finishing) continue;
      if (_wentBack(p)) {
        dropped = d.pieces.remove(p);
        continue;
      }
      final o = moved?[p.owner];
      final follows = to != null && o != null && _attached.containsKey(to);
      p.owner = follows ? o : null;
      p.rs = follows ? to : null;
    }
    if (dropped) _save(d, null);
  }

  /// The session ended ([rs]: null when it never went live): with the record on, the records left
  /// unwritten go, what is left unsent becomes one `draft` record and the file goes; with it off,
  /// the file stays for the next open. [record]: the app's switch, else [rs]'s.
  Future<void> sessionEnded(RemoteSession? rs, SessionMeta meta, {bool? record}) async {
    final d = _drafts.remove(meta.key) ?? _load(meta.key);
    for (final s in [for (final e in _attached.entries) if (e.value.key == meta.key) e.key]) {
      _attached.remove(s);
      _unhook(s);
    }
    final on = enabled() && (record ?? rs?.recordsInput ?? d.meta['record'] != false);
    if (rs != null) d.text = rs.composer.draftText;
    await Future.wait([...d.busy]);
    if (!on || !await _flush(d)) {
      await _persist(d);
      return;
    }
    final text = _join([for (final p in d.pieces) if (!p.finishing && !_wentBack(p)) p.text], d.text);
    if (text.isNotEmpty) {
      final at = _clock();
      if (!await _write(null, _draftRecord(meta, text, at), at)) {
        await _persist(d);
        return;
      }
    }
    await _delete(meta.key);
  }

  /// Drafts last touched more than [age] ago (a session never ended, an app quit) become `draft`
  /// records, after the records they kept; apps that do not record, and everything while the
  /// record is off, are left alone.
  Future<void> sweep({Duration age = const Duration(days: 7)}) async {
    if (!enabled()) return;
    final List<(DraftFile, DateTime)> all;
    try {
      all = _store.scan();
    } catch (e) {
      _log('rapp: 输入记录 清理失败：${_reason(e)}');
      return;
    }
    final now = _clock();
    var n = 0;
    for (final (f, modified) in all) {
      if (now.difference(modified) <= age || !_records(f.key, f.meta) || _drafts.containsKey(f.key)) continue;
      final left = [...f.records];
      while (left.isNotEmpty && await _write(null, left.first, _atOf(left.first))) {
        left.removeAt(0);
      }
      final text = _join(f.pending, f.text);
      final m = SessionMeta.fromJson(f.key, f.meta);
      if (left.isNotEmpty || (text.isNotEmpty && !await _write(null, _draftRecord(m, text, now), now))) {
        if (left.length != f.records.length && !_drafts.containsKey(f.key)) {
          await _store.save(f..records = left).catchError((Object e) => _log('rapp: 输入记录 草稿没存上：${_reason(e)}'));
        }
        break;
      }
      if (_drafts.containsKey(f.key)) continue; // opened meanwhile: its file is live again
      await _delete(f.key);
      n++;
    }
    if (n > 0) _log('rapp: 输入记录 清理 $n 份草稿');
  }

  _Draft _load(String key) {
    final d = _Draft(key);
    final f = _store.load(key);
    if (f != null) {
      d.text = f.text;
      d.pieces.addAll([for (final t in f.pending) _Piece(t, null, null)]);
      d.stored.addAll(f.records);
      d.meta = f.meta;
    }
    return d;
  }

  void _unhook(RemoteSession rs) {
    rs.composer
      ..onDraftChanged = null
      ..onSubmitted = null
      ..onFinished = null;
  }

  /// [p]'s row went back into the editor (`putBack`): its text is in the draft now.
  static bool _wentBack(_Piece p) {
    final o = p.owner, rs = p.rs;
    if (o == null || rs == null || p.finishing) return false;
    return !identical(rs.composer.inFlight, o) && !rs.composer.failed.contains(o);
  }

  /// Whether a draft nobody has open may become records: the switch saved with it and the
  /// app's switch as it is now must both be on.
  bool _records(String key, Map<String, Object?> meta) =>
      meta['record'] != false && (recordsApp?.call(SessionMeta.fromJson(key, meta).appId) ?? true);

  /// Writes [d] (with [rs]'s session as it is now), unless its session has ended.
  void _save(_Draft d, RemoteSession? rs) {
    if (!identical(_drafts[d.key], d)) return;
    final a = rs == null ? null : _attached[rs];
    if (rs != null && a != null) d.meta = {...a.meta().toJson(), 'record': rs.recordsInput};
    unawaited(_persist(d));
  }

  Future<void> _persist(_Draft d) => _store
      .save(DraftFile(
          key: d.key,
          text: d.text,
          pending: [for (final p in d.pieces) p.text],
          records: [...d.stored],
          meta: d.meta))
      .catchError((Object e) => _log('rapp: 输入记录 草稿没存上：${_reason(e)}'));

  Future<void> _delete(String key) =>
      _store.delete(key).catchError((Object e) => _log('rapp: 输入记录 草稿没删掉：${_reason(e)}'));

  Future<void> _finished(_Draft d, RemoteSession rs, Outgoing o, bool all) async {
    final p = d.pieces.where((p) => identical(p.owner, o)).firstOrNull;
    final a = _attached[rs];
    var changed = false;
    if (a != null && enabled() && rs.recordsInput) {
      final at = o.at ?? _clock();
      final rec = _sentRecord(_handed[o] ?? a.meta(), o, all, rs.profile.afterSend, at);
      p?.finishing = true;
      final ok = await _write(rs, rec, at);
      p?.finishing = false;
      if (!ok) {
        d.stored.add(rec); // the round is over: it waits as a record, never as unsent text
        changed = true;
      }
    }
    if (p != null && d.pieces.remove(p)) changed = true;
    if (changed) _save(d, rs);
  }

  /// Appends [d]'s unwritten records, oldest first, after any append of them already running;
  /// true when none is left.
  Future<bool> _flush(_Draft d) {
    final run = d.flushing.then((_) async {
      var n = 0;
      while (d.stored.isNotEmpty) {
        final r = d.stored.first;
        final why = await _append(r, _atOf(r));
        if (why != null) {
          _log('rapp: 输入记录 补写失败：$why');
          break;
        }
        d.stored.remove(r);
        n++;
      }
      if (n > 0) {
        _log('rapp: 输入记录 补写 $n 条');
        _save(d, null);
      }
      return d.stored.isEmpty;
    });
    d.flushing = run.catchError((Object _) => false);
    return run;
  }

  /// After a write that went: the records other sessions keep waiting go too.
  Future<void> _flushAll() async {
    if (!enabled()) return;
    for (final d in [..._drafts.values]) {
      if (d.stored.isNotEmpty && _records(d.key, d.meta)) await _flush(d);
    }
  }

  /// Appends one record; false (said once on [rs]'s composer) when it did not go.
  Future<bool> _write(RemoteSession? rs, Map<String, Object?> rec, DateTime at) async {
    final why = await _append(rec, at);
    if (why == null) {
      _failSaid = false;
      unawaited(_flushAll());
      return true;
    }
    _log('rapp: 输入记录 写入失败：$why');
    if (rs != null && !_failSaid && _attached.containsKey(rs)) {
      _failSaid = true;
      try {
        rs.composer.note('输入记录没写进去：$why');
      } catch (_) {
        // The session went (disposed) while the write ran.
      }
    }
    return false;
  }

  /// Appends [rec] (its `from` filled in when it was built without a device id); null when it
  /// went, else why not.
  Future<String?> _append(Map<String, Object?> rec, DateTime at) async {
    final dd = data();
    final id = dd.deviceId();
    if (id == null) return '还不知道这台设备的 id';
    rec['from'] ??= {'id': id, 'name': _deviceName(dd, id)};
    try {
      _inputsDir = dd.inputsDir(id);
      await _input.append(rec, at);
    } catch (e) {
      return _reason(e);
    }
    _written.add(rec);
    return null;
  }

  /// A built record's own time (its day file), read back from `ts`.
  DateTime _atOf(Map<String, Object?> rec) {
    final ts = rec['ts'];
    return (ts is String ? DateTime.tryParse(ts) : null) ?? _clock();
  }

  /// `name` in this device's `device.json` (the service writes it), else the id.
  String _deviceName(DataDir dd, String id) {
    try {
      final v = jsonDecode(File('${dd.deviceDir(id)}/device.json').readAsStringSync());
      final n = v is Map ? v['name'] : null;
      if (n is String && n.isNotEmpty) return n;
    } catch (_) {}
    return id;
  }

  /// `from` stays null until the record is written (the device id may come later).
  Map<String, Object?> _common(String kind, SessionMeta m, String text, DateTime at) => {
        'v': 1,
        'id': newRecordId(at),
        'ts': isoWithOffset(at),
        'kind': kind,
        'from': null,
        'host': {'id': m.hostId, 'name': m.hostName},
        'app': {'id': m.appId, 'name': m.appName},
        'session': m.key,
        'run': m.run,
        if (m.windowId != null) 'window': {'id': m.windowId, if (m.windowTitle != null) 'title': m.windowTitle},
        'projects': m.projects,
        'text': text,
      };

  Map<String, Object?> _sentRecord(SessionMeta m, Outgoing o, bool all, AfterSend after, DateTime at) {
    final total = o.pieces().length;
    return {
      ..._common('sent', m, o.text, at),
      'blocks': [
        for (final b in o.blocks)
          {
            if (b.kind != null) 'kind': b.kind,
            'label': b.label,
            if (b.bytes != null) 'bytes': b.bytes,
            if (b.text != null) 'text': b.text,
            if (b.name != null) 'name': b.name,
          },
      ],
      'result': o.sent >= total ? 'sent' : (o.sent > 0 ? 'partial' : 'failed'),
      if (o.sent > 0 && o.sent < total) 'sentPieces': o.sent,
      // Return was pressed only when every piece went and nothing was said.
      'after': all && o.failure == null && after == AfterSend.pressReturn ? 'return' : 'none',
      'source': 'typed',
    };
  }

  Map<String, Object?> _draftRecord(SessionMeta m, String text, DateTime at) =>
      {..._common('draft', m, text, at), 'blocks': const <Object>[], 'source': 'typed'};

  static String _join(List<String> pending, String text) =>
      [...pending, text].where((s) => s.isNotEmpty).join('\n');

  static String _reason(Object e) => e is FileSystemException ? (e.osError?.message ?? e.message) : '$e';
}
