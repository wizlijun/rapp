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

/// A sent piece whose record is not written yet: its text stays in the draft file until then.
class _Piece {
  _Piece(this.text, this.owner, this.rs);
  final String text;

  /// The send it is; null for one read back from a file.
  final Outgoing? owner;
  final RemoteSession? rs;

  /// Its record is being written: a draft record made meanwhile leaves it out.
  bool finishing = false;
}

/// One session key's draft as the file holds it.
class _Draft {
  _Draft(this.key);
  final String key;
  String text = '';
  final pieces = <_Piece>[];
  Map<String, Object?> meta = {};
}

class InputRecorder {
  /// [enabled]: the overall switch (`gui.json` `inputHistory`); each session's app has its own.
  InputRecorder({required this.data, required this.enabled, void Function(String)? log, DateTime Function()? clock})
      : _log = log ?? ((_) {}),
        _clock = clock ?? DateTime.now {
    _store = DraftStore(() => data().draftsDir);
    _input = InputLog(() => _inputsDir);
  }

  final DataDir Function() data;
  final bool Function() enabled;
  final void Function(String) _log;
  final DateTime Function() _clock;
  late final DraftStore _store;
  late final InputLog _input;
  String _inputsDir = '';
  final _written = StreamController<Map<String, Object?>>.broadcast();
  final Map<String, _Draft> _drafts = {};
  final Map<RemoteSession, ({String key, SessionMeta Function() meta})> _attached = {};

  /// A failure was said and no write has gone since.
  bool _failSaid = false;

  /// Every record, once it is written.
  Stream<Map<String, Object?>> get written => _written.stream;

  /// Follows [rs]'s composer from now on. [restore]: a new open (no older session hands its
  /// text over), so the draft file's pieces and text go back into the composer.
  void attach(RemoteSession rs, SessionMeta Function() meta, {required bool restore}) {
    final m = meta();
    final d = _drafts[m.key] ??= _load(m.key);
    _attached[rs] = (key: m.key, meta: meta);
    final c = rs.composer;
    if (restore && (d.pieces.isNotEmpty || d.text.isNotEmpty)) {
      final t = [for (final p in d.pieces) p.text, d.text].where((s) => s.isNotEmpty).join('\n');
      d.pieces.clear();
      d.text = t;
      c.setDraft(t);
      _save(d, rs);
    }
    c.onDraftChanged = (t) {
      d.text = t;
      _save(d, rs);
    };
    c.onSubmitted = (o) {
      // A retry after a failed write is still pending: its text is there once already.
      if (o.text.isEmpty || d.pieces.any((p) => identical(p.owner, o))) return;
      d.pieces.add(_Piece(o.text, o, rs));
      _save(d, rs);
    };
    c.onFinished = (o, {required all}) => _finished(d, rs, o, all);
  }

  /// [rs] went for good while its session goes on in another (a reconnect's swap): its hooks are
  /// off, and the pieces whose text came over as failed rows are no longer pending here.
  void detach(RemoteSession rs) {
    final a = _attached.remove(rs);
    if (a == null) return;
    final c = rs.composer;
    _unhook(rs);
    final d = _drafts[a.key];
    if (d == null) return;
    final n = d.pieces.length;
    d.pieces.removeWhere((p) =>
        identical(p.rs, rs) && !p.finishing && (identical(p.owner, c.inFlight) || c.failed.contains(p.owner)));
    if (d.pieces.length != n) _save(d, null);
  }

  /// The session ended: with the record on, what is left unsent becomes one `draft` record and
  /// the file goes; with it off, the file stays for the next open.
  Future<void> sessionEnded(RemoteSession rs, SessionMeta meta) async {
    final d = _drafts.remove(meta.key);
    for (final s in [for (final e in _attached.entries) if (e.value.key == meta.key) e.key]) {
      _attached.remove(s);
      _unhook(s);
    }
    if (d == null || !(enabled() && rs.recordsInput)) return;
    final text = _join([for (final p in d.pieces) if (!p.finishing) p.text], rs.composer.draft);
    if (text.isNotEmpty) {
      final at = _clock();
      if (!await _write(null, (from) => _draftRecord(from, meta, text, at), at)) return;
    }
    await _delete(meta.key);
  }

  /// Drafts last touched more than [age] ago (a session never ended, an app quit) become `draft`
  /// records; apps that do not record, and everything while the record is off, are left alone.
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
      if (now.difference(modified) <= age || f.meta['record'] == false || _drafts.containsKey(f.key)) continue;
      final text = _join(f.pending, f.text);
      if (text.isNotEmpty) {
        final m = SessionMeta.fromJson(f.key, f.meta);
        if (!await _write(null, (from) => _draftRecord(from, m, text, now), now)) break;
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

  /// Writes [d] (with [rs]'s session as it is now), unless its session has ended.
  void _save(_Draft d, RemoteSession? rs) {
    if (!identical(_drafts[d.key], d)) return;
    final a = rs == null ? null : _attached[rs];
    if (rs != null && a != null) d.meta = {...a.meta().toJson(), 'record': rs.recordsInput};
    final f = DraftFile(key: d.key, text: d.text, pending: [for (final p in d.pieces) p.text], meta: d.meta);
    _store.save(f).catchError((Object e) => _log('rapp: 输入记录 草稿没存上：${_reason(e)}'));
  }

  Future<void> _delete(String key) =>
      _store.delete(key).catchError((Object e) => _log('rapp: 输入记录 草稿没删掉：${_reason(e)}'));

  Future<void> _finished(_Draft d, RemoteSession rs, Outgoing o, bool all) async {
    final p = d.pieces.where((p) => identical(p.owner, o)).firstOrNull;
    final a = _attached[rs];
    if (a != null && enabled() && rs.recordsInput) {
      final m = a.meta();
      final at = o.at ?? _clock();
      p?.finishing = true;
      final ok = await _write(rs, (from) => _sentRecord(from, m, o, all, rs.profile.afterSend, at), at);
      p?.finishing = false;
      if (!ok) return; // stays pending: the next open brings it back
    }
    if (p != null && d.pieces.remove(p)) _save(d, rs);
  }

  /// Appends one record; false (said once on [rs]'s composer) when it did not go.
  Future<bool> _write(RemoteSession? rs, Map<String, Object?> Function(Map<String, Object?> from) build, DateTime at) async {
    final dd = data();
    final id = dd.deviceId();
    String why;
    if (id == null) {
      why = '还不知道这台设备的 id';
    } else {
      final rec = build({'id': id, 'name': _deviceName(dd, id)});
      try {
        _inputsDir = dd.inputsDir(id);
        await _input.append(rec, at);
        _failSaid = false;
        _written.add(rec);
        return true;
      } catch (e) {
        why = _reason(e);
      }
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

  /// `name` in this device's `device.json` (the service writes it), else the id.
  String _deviceName(DataDir dd, String id) {
    try {
      final v = jsonDecode(File('${dd.deviceDir(id)}/device.json').readAsStringSync());
      final n = v is Map ? v['name'] : null;
      if (n is String && n.isNotEmpty) return n;
    } catch (_) {}
    return id;
  }

  Map<String, Object?> _common(String kind, Map<String, Object?> from, SessionMeta m, String text, DateTime at) => {
        'v': 1,
        'id': newRecordId(at),
        'ts': isoWithOffset(at),
        'kind': kind,
        'from': from,
        'host': {'id': m.hostId, 'name': m.hostName},
        'app': {'id': m.appId, 'name': m.appName},
        'session': m.key,
        'run': m.run,
        if (m.windowId != null) 'window': {'id': m.windowId, if (m.windowTitle != null) 'title': m.windowTitle},
        'projects': m.projects,
        'text': text,
      };

  Map<String, Object?> _sentRecord(
      Map<String, Object?> from, SessionMeta m, Outgoing o, bool all, AfterSend after, DateTime at) {
    final total = o.pieces().length;
    return {
      ..._common('sent', from, m, o.text, at),
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
      'after': all && after == AfterSend.pressReturn ? 'return' : 'none',
      'source': 'typed',
    };
  }

  Map<String, Object?> _draftRecord(Map<String, Object?> from, SessionMeta m, String text, DateTime at) =>
      {..._common('draft', from, m, text, at), 'blocks': const <Object>[], 'source': 'typed'};

  static String _join(List<String> pending, String text) =>
      [...pending, text].where((s) => s.isNotEmpty).join('\n');

  static String _reason(Object e) => e is FileSystemException ? (e.osError?.message ?? e.message) : '$e';
}
