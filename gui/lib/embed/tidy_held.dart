// A waiting tidy's original, on disk while it waits (review 2026-11-20 minor): a quit or a crash with the card
// still up would lose it otherwise. One small private file per session key; the next open of that key puts it
// back into the draft and the file goes.
import 'dart:convert';
import 'dart:io';

import '../data_dir.dart' show writePrivate;

class TidyHeld {
  TidyHeld(this.dir);

  /// Where the files go (`local/tidy-held/`), asked each time: a relocate moves it.
  final String Function() dir;

  String _path(String key) => '${dir()}/${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}.txt';

  /// [text] waits for [key]; null: nothing waits any more.
  void set(String key, String? text) {
    try {
      final f = File(_path(key));
      if (text == null) {
        if (f.existsSync()) f.deleteSync();
        return;
      }
      Directory(dir()).createSync(recursive: true);
      writePrivate(f.path, utf8.encode(text));
    } catch (_) {
      // Best effort: the original is still on the card and in memory.
    }
  }

  /// What waited for [key], once.
  String? take(String key) {
    try {
      final f = File(_path(key));
      if (!f.existsSync()) return null;
      final t = f.readAsStringSync();
      f.deleteSync();
      return t.trim().isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }
}
