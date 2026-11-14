// Append-only input history: one JSON line per record in `<dir>/YYYY-MM-DD.jsonl`.
import 'dart:convert';
import 'dart:io';

class InputLog {
  InputLog(this.dir);
  final String Function() dir;
  Future<void> _tail = Future.value();

  /// Appends [record] to the file of [at]'s local date. Appends run in call order;
  /// a failure completes the returned future with the error and does not block later ones.
  Future<void> append(Map<String, Object?> record, DateTime at) {
    final d = dir();
    final line = '${jsonEncode(record)}\n';
    final l = at.toLocal();
    String p(int n) => n.toString().padLeft(2, '0');
    final path = '$d/${l.year.toString().padLeft(4, '0')}-${p(l.month)}-${p(l.day)}.jsonl';
    final run = _tail.then((_) async {
      await Directory(d).create(recursive: true);
      await File(path).writeAsString(line, mode: FileMode.append, flush: true);
    });
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }
}
