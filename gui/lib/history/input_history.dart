// The input record read back (spec 2026-11-14-rapp-input-history §4, §6): every device's
// `devices/*/inputs/*.jsonl`, merged by `id`, newest first.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../paths.dart';
import 'input_log.dart';
import 'record_id.dart';

/// One record as read back.
class InputEntry {
  InputEntry._({
    required this.id,
    required this.ts,
    required this.kind,
    required this.deviceId,
    required this.session,
    required this.hostId,
    required this.hostName,
    required this.appName,
    required this.windowTitle,
    required this.text,
    required this.day,
    required this.raw,
    required this.mine,
  });

  final String id;
  final DateTime ts;

  /// `sent` or `draft`.
  final String kind;

  /// `from.id`: the device that wrote it.
  final String deviceId;
  final String session;
  final String hostId, hostName, appName;
  final String? windowTitle;
  final String text;

  /// The day file it is in (`YYYY-MM-DD`).
  final String day;

  /// The record as it was read.
  final Map<String, Object?> raw;

  /// Written by this device (only those can be taken out of the record).
  final bool mine;

  /// Sent by a 常用语 tap (`source: phrase`): listed, but ↑ skips it.
  bool get phrase => raw['source'] == 'phrase';

  /// The heard text when the record's text is the AI's (`ai.original`, 长语音先让 AI 整理); else null.
  String? get aiOriginal {
    final ai = raw['ai'];
    final o = ai is Map ? ai['original'] : null;
    return o is String ? o : null;
  }

  /// [raw] as an entry, or null when it lacks what every record has. [day]: its file's name;
  /// else the local date `ts` was written with.
  static InputEntry? parse(Map<String, Object?> raw, {String? day, String? me}) {
    final id = raw['id'], ts = raw['ts'], kind = raw['kind'], session = raw['session'], text = raw['text'];
    if (id is! String || id.isEmpty || ts is! String || kind is! String || session is! String || text is! String) {
      return null;
    }
    final at = DateTime.tryParse(ts);
    if (at == null) return null;
    String part(String field, String key) {
      final m = raw[field];
      return m is Map && m[key] is String ? m[key] as String : '';
    }

    final w = raw['window'];
    final from = part('from', 'id');
    return InputEntry._(
      id: id,
      ts: at,
      kind: kind,
      deviceId: from,
      session: session,
      hostId: part('host', 'id'),
      hostName: part('host', 'name'),
      appName: part('app', 'name'),
      windowTitle: w is Map && w['title'] is String ? w['title'] as String : null,
      text: text,
      day: day ?? (ts.length >= 10 ? ts.substring(0, 10) : ''),
      raw: raw,
      mine: me != null && from == me,
    );
  }

  /// A send this run kept only in memory (R2: ↑ brings it back whether the record is on or not).
  factory InputEntry.memory(String session, String text, DateTime at) {
    final id = newRecordId(at);
    final ts = isoWithOffset(at);
    return InputEntry._(
      id: id,
      // To the second, as a record's `ts`: the record of this send (a later id) sorts before it
      // and this copy drops out as the same text twice in a row.
      ts: DateTime.parse(ts),
      kind: 'sent',
      deviceId: '',
      session: session,
      hostId: '',
      hostName: '',
      appName: '',
      windowTitle: null,
      text: text,
      day: ts.substring(0, 10),
      raw: const {},
      mine: false,
    );
  }
}

/// A day file as last read: re-read only when its length or modification time changed.
class _Read {
  _Read(this.length, this.modified, this.entries);
  final int length;
  final DateTime modified;
  final List<InputEntry> entries;
}

class InputHistory extends ChangeNotifier {
  InputHistory({required this.data, void Function(String)? log}) : _log = log ?? ((_) {});

  final DataDir Function() data;
  final void Function(String) _log;

  final Map<String, _Read> _files = {};

  /// Records handed over by [add] (written by this device since they were last read).
  final Map<String, InputEntry> _added = {};

  /// Sends of this run, kept for ↑ only (never in [search], never on disk), oldest first.
  final List<InputEntry> _memory = [];

  List<InputEntry>? _all;
  final Map<String, List<InputEntry>> _sessions = {};
  Future<void> _tail = Future.value();
  bool _disposed = false;

  /// Reads what changed on disk since the last time. Never throws; refreshes run one at a time.
  Future<void> refresh() => _tail = _tail.then((_) => _scan()).catchError((Object e) {
        _log('rapp: 输入历史 读取失败：${_reason(e)}');
      });

  Future<void> _scan() async {
    final dd = data();
    final me = dd.deviceId();
    final devices = Directory(dd.devicesDir);
    final seen = <String>{};
    var changed = false, read = 0, bad = 0, failed = 0;
    if (await devices.exists()) {
      await for (final dev in devices.list(followLinks: false)) {
        if (dev is! Directory) continue;
        final inputs = Directory('${dev.path}/inputs');
        if (!await inputs.exists()) continue;
        await for (final f in inputs.list(followLinks: false)) {
          if (f is! File || !f.path.endsWith('.jsonl')) continue;
          seen.add(f.path);
          try {
            final st = await f.stat();
            final old = _files[f.path];
            if (old != null && old.length == st.size && old.modified == st.modified) continue;
            final name = f.uri.pathSegments.last;
            final day = name.substring(0, name.length - '.jsonl'.length);
            final entries = <InputEntry>[];
            for (final line in const LineSplitter().convert(utf8.decode(await f.readAsBytes(), allowMalformed: true))) {
              if (line.trim().isEmpty) continue;
              final e = _parseLine(line, day, me);
              if (e == null) {
                bad++;
              } else {
                entries.add(e);
              }
            }
            _files[f.path] = _Read(st.size, st.modified, entries);
            changed = true;
            read++;
          } catch (_) {
            failed++;
          }
        }
      }
    }
    for (final p in [..._files.keys]) {
      if (!seen.contains(p)) {
        _files.remove(p);
        changed = true;
      }
    }
    if (read > 0 || bad > 0 || failed > 0) _log('rapp: 输入历史 读了 $read 个文件，跳过 $bad 行，$failed 个没读成');
    if (changed) _changed();
  }

  static InputEntry? _parseLine(String line, String day, String? me) {
    try {
      final v = jsonDecode(line);
      return v is Map<String, Object?> ? InputEntry.parse(v, day: day, me: me) : null;
    } catch (_) {
      return null;
    }
  }

  /// A record just written (the recorder's `written`); one that lacks a field is skipped.
  void add(Map<String, Object?> record) {
    final e = InputEntry.parse(record, me: data().deviceId());
    if (e == null || _added.containsKey(e.id)) return;
    _added[e.id] = e;
    _changed();
  }

  /// [text] was just sent in session [key]: ↑ brings it back in this run, the record on or off.
  void remember(String key, String text, DateTime at) {
    if (text.isEmpty) return;
    _memory.add(InputEntry.memory(key, text, at));
    _changed();
  }

  void _changed() {
    _all = null;
    _sessions.clear();
    if (!_disposed) notifyListeners();
  }

  /// Every record, one per `id`, newest first.
  List<InputEntry> get _entries {
    final all = _all;
    if (all != null) return all;
    final byId = <String, InputEntry>{for (final e in _added.values) e.id: e};
    for (final r in _files.values) {
      for (final e in r.entries) {
        byId[e.id] = e;
      }
    }
    final list = byId.values.toList()..sort(_newestFirst);
    return _all = List.unmodifiable(list);
  }

  /// What ↑ brings back for session [key], newest first: its records with text and this run's sends
  /// ([remember]); of the same text twice in a row only the newer stays. [prefix]: every session whose
  /// key starts with [key] (a host's text terminals share one history).
  List<InputEntry> forSession(String key, {bool prefix = false}) =>
      _sessions[prefix ? '$key*' : key] ??= List.unmodifiable(() {
        bool ours(InputEntry e) => prefix ? e.session.startsWith(key) : e.session == key;
        final all = [
          for (final e in _entries)
            if (ours(e) && e.text.isNotEmpty) e,
          for (final e in _memory)
            if (ours(e)) e,
        ]..sort(_newestFirst);
        final out = <InputEntry>[];
        for (final e in all) {
          if (out.isNotEmpty && out.last.text == e.text) continue;
          out.add(e);
        }
        return out;
      }());

  static int _newestFirst(InputEntry a, InputEntry b) {
    final c = b.ts.compareTo(a.ts);
    return c != 0 ? c : b.id.compareTo(a.id);
  }

  /// The records whose text holds [q] (any case), newest first; [session] or [host] narrow it.
  List<InputEntry> search(String q, {String? session, String? host}) {
    final needle = q.toLowerCase();
    return [
      for (final e in _entries)
        if ((session == null || e.session == session) &&
            (host == null || e.hostId == host) &&
            (needle.isEmpty || e.text.toLowerCase().contains(needle)))
          e,
    ];
  }

  /// Takes [e] out of its day file (only this device's); the other lines stay as they were.
  Future<void> remove(InputEntry e) {
    // ↑ stops bringing it back too: this run's copy goes with it.
    final before = _memory.length;
    _memory.removeWhere((m) => m.session == e.session && m.text == e.text);
    if (_memory.length != before) _changed();
    if (!e.mine) return Future.value();
    return _tail = _tail.then((_) => _remove(e)).catchError((Object err) {
      _log('rapp: 输入历史 去掉失败：${_reason(err)}');
    });
  }

  Future<void> _remove(InputEntry e) async {
    final dd = data();
    final me = dd.deviceId();
    if (me != null) {
      // Queued behind the appends already asked for (the recorder's), so the line is there to drop.
      await InputLog.dropLine('${dd.inputsDir(me)}/${e.day}.jsonl', e.id);
    }
    _added.remove(e.id);
    _changed();
    await _scan(); // the file changed: read it again
  }


  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static String _reason(Object e) => e is FileSystemException ? (e.osError?.message ?? e.message) : '$e';
}
