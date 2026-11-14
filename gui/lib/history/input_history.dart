// The input record read back (spec 2026-11-14-rapp-input-history §4, §6): every device's
// `devices/*/inputs/*.jsonl`, merged by `id`, newest first.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data_dir.dart';
import '../paths.dart';

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
            for (final line in const LineSplitter().convert(await f.readAsString())) {
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
    final list = byId.values.toList()
      ..sort((a, b) {
        final c = b.ts.compareTo(a.ts);
        return c != 0 ? c : b.id.compareTo(a.id);
      });
    return _all = List.unmodifiable(list);
  }

  /// Session [key]'s records with text, newest first; of the same text twice in a row only the
  /// newer stays.
  List<InputEntry> forSession(String key) => _sessions[key] ??= List.unmodifiable(() {
        final out = <InputEntry>[];
        for (final e in _entries) {
          if (e.session != key || e.text.isEmpty) continue;
          if (out.isNotEmpty && out.last.text == e.text) continue;
          out.add(e);
        }
        return out;
      }());

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
    if (!e.mine) return Future.value();
    return _tail = _tail.then((_) => _remove(e)).catchError((Object err) {
      _log('rapp: 输入历史 去掉失败：${_reason(err)}');
    });
  }

  Future<void> _remove(InputEntry e) async {
    final dd = data();
    final me = dd.deviceId();
    final path = '${dd.inputsDir(me ?? '')}/${e.day}.jsonl';
    final f = File(path);
    if (me != null && await f.exists()) {
      final bytes = await f.readAsBytes();
      final out = BytesBuilder(copy: false);
      var from = 0, dropped = false;
      while (from < bytes.length) {
        var to = bytes.indexOf(0x0A, from);
        to = to < 0 ? bytes.length : to + 1;
        final line = bytes.sublist(from, to);
        from = to;
        if (_idOf(line) == e.id) {
          dropped = true;
        } else {
          out.add(line);
        }
      }
      if (dropped) {
        writePrivate(path, out.takeBytes());
        final st = await f.stat();
        final old = _files[path];
        if (old != null) {
          _files[path] = _Read(st.size, st.modified, [
            for (final x in old.entries)
              if (x.id != e.id) x,
          ]);
        }
      }
    }
    _added.remove(e.id);
    _changed();
  }

  static String? _idOf(List<int> line) {
    try {
      final v = jsonDecode(utf8.decode(line, allowMalformed: true));
      return v is Map && v['id'] is String ? v['id'] as String : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static String _reason(Object e) => e is FileSystemException ? (e.osError?.message ?? e.message) : '$e';
}
