// Unsent drafts: one private (0600) file per session key in `local/drafts/`.
import 'dart:convert';
import 'dart:io';

import '../data_dir.dart';

class DraftFile {
  DraftFile({required this.key, this.text = '', List<String>? pending, Map<String, Object?>? meta})
      : pending = pending ?? [],
        meta = meta ?? {};
  String key;
  String text;
  List<String> pending;
  Map<String, Object?> meta;

  Map<String, Object?> toJson() => {'v': 1, 'key': key, 'text': text, 'pending': pending, 'meta': meta};

  static DraftFile? fromJson(Object? j) {
    if (j is! Map || j['v'] != 1 || j['key'] is! String) return null;
    final text = j['text'], pending = j['pending'], meta = j['meta'];
    if (text is! String || pending is! List || pending.any((e) => e is! String)) return null;
    return DraftFile(
      key: j['key'] as String,
      text: text,
      pending: pending.cast<String>().toList(),
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
    if (d.text.isEmpty && d.pending.isEmpty) return delete(d.key);
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
