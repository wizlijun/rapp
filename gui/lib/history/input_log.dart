// Append-only input history: one JSON line per record in `<dir>/YYYY-MM-DD.jsonl`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data_dir.dart';

class InputLog {
  InputLog(this.dir);
  final String Function() dir;

  /// Per file: the last thing queued on it. Appends and [dropLine] of one file never interleave,
  /// whoever asks (the recorder's log and the history's removal share this).
  static final Map<String, Future<void>> _chains = {};

  static Future<T> _queued<T>(String path, Future<T> Function() job) {
    final run = (_chains[path] ?? Future<void>.value()).then((_) => job());
    _chains[path] = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Appends [record] to the file of [at]'s local date. Appends run in call order;
  /// a failure completes the returned future with the error and does not block later ones.
  Future<void> append(Map<String, Object?> record, DateTime at) {
    final d = dir();
    final line = '${jsonEncode(record)}\n';
    final l = at.toLocal();
    String p(int n) => n.toString().padLeft(2, '0');
    final path = '$d/${l.year.toString().padLeft(4, '0')}-${p(l.month)}-${p(l.day)}.jsonl';
    return _queued(path, () async {
      await Directory(d).create(recursive: true);
      await File(path).writeAsString(line, mode: FileMode.append, flush: true);
    });
  }

  /// Rewrites the file at [path] without the line whose `id` is [id] (temporary file, then rename);
  /// every other line stays byte for byte. Queued behind the appends already asked for.
  /// True when a line was taken out.
  static Future<bool> dropLine(String path, String id) => _queued(path, () async {
        final f = File(path);
        if (!await f.exists()) return false;
        final bytes = await f.readAsBytes();
        final out = BytesBuilder(copy: false);
        var from = 0, dropped = false;
        while (from < bytes.length) {
          var to = bytes.indexOf(0x0A, from);
          to = to < 0 ? bytes.length : to + 1;
          final line = bytes.sublist(from, to);
          from = to;
          if (_idOf(line) == id) {
            dropped = true;
          } else {
            out.add(line);
          }
        }
        if (dropped) writePrivate(path, out.takeBytes());
        return dropped;
      });

  static String? _idOf(List<int> line) {
    try {
      final v = jsonDecode(utf8.decode(line, allowMalformed: true));
      return v is Map && v['id'] is String ? v['id'] as String : null;
    } catch (_) {
      return null;
    }
  }
}
