// Unsent drafts: one private (0600) file per session key in `local/drafts/`.
import 'dart:convert';
import 'dart:io';

import '../data_dir.dart';

class DraftFile {
  DraftFile({required this.key, this.text = '', List<String>? pending, List<Map<String, Object?>>? records, Map<String, Object?>? meta})
      : pending = pending ?? [],
        records = records ?? [],
        meta = meta ?? {};
  String key;
  String text;

  /// Sent text whose round has not finished (a crash mid-send brings it back).
  List<String> pending;

  /// Built records of finished rounds whose write failed: appended later, never text again.
  List<Map<String, Object?>> records;
  Map<String, Object?> meta;

  /// `pending` holds both: a string, or `{text, record}` for a built record (older files have
  /// only strings).
  Map<String, Object?> toJson() => {
        'v': 1,
        'key': key,
        'text': text,
        'pending': [
          ...pending,
          for (final r in records) {'text': r['text'] is String ? r['text'] : '', 'record': r},
        ],
        'meta': meta,
      };

  static DraftFile? fromJson(Object? j) {
    if (j is! Map || j['v'] != 1 || j['key'] is! String) return null;
    final text = j['text'], pending = j['pending'], meta = j['meta'];
    if (text is! String || pending is! List) return null;
    final ps = <String>[];
    final rs = <Map<String, Object?>>[];
    for (final e in pending) {
      if (e is String) {
        ps.add(e);
      } else if (e is Map && e['record'] is Map) {
        rs.add((e['record'] as Map).cast<String, Object?>());
      } else {
        return null;
      }
    }
    return DraftFile(
      key: j['key'] as String,
      text: text,
      pending: ps,
      records: rs,
      meta: meta is Map ? meta.cast<String, Object?>() : {},
    );
  }
}

class DraftStore {
  DraftStore(this.dir);
  final String Function() dir;
  final Map<String, Future<void>> _tails = {};

  /// One flat file name per key: the key's UTF-8 as unpadded base64url, plus `.json`.
  String pathFor(String key) => '${dir()}/${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}.json';

  DraftFile? _read(String path) {
    try {
      return DraftFile.fromJson(jsonDecode(File(path).readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  DraftFile? load(String key) => _read(pathFor(key));

  Future<void> _serial(String key, Future<void> Function() op) {
    final run = (_tails[key] ?? Future.value()).then((_) => op());
    final tail = run.then((_) {}, onError: (_) {});
    _tails[key] = tail;
    tail.then((_) {
      if (identical(_tails[key], tail)) _tails.remove(key);
    });
    return run;
  }

  /// Writes [d]; an empty draft with nothing pending deletes the file instead.
  Future<void> save(DraftFile d) {
    if (d.text.isEmpty && d.pending.isEmpty && d.records.isEmpty) return delete(d.key);
    final path = pathFor(d.key);
    final data = utf8.encode(jsonEncode(d.toJson()));
    return _serial(d.key, () async => writePrivate(path, data));
  }

  Future<void> delete(String key) {
    final path = pathFor(key);
    return _serial(key, () async {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    });
  }

  /// Every readable draft with its file's modified time; broken files are skipped, not deleted.
  List<(DraftFile, DateTime modified)> scan() {
    final d = Directory(dir());
    if (!d.existsSync()) return [];
    final out = <(DraftFile, DateTime)>[];
    for (final e in d.listSync()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      final f = _read(e.path);
      if (f != null) out.add((f, e.statSync().modified));
    }
    return out;
  }
}
