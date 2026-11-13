// Pinned clipboard entries as files in the data dir (spec D5): names, listing, deleting.
// Nothing here logs: titles and paths are the person's own.
import 'dart:io';

import '../embed/session_port.dart';
import '../paths.dart';
import 'resources_state.dart';

const pinHint = '固定的条目存进了数据目录；文字会进 git 历史，取消固定只删文件，历史里还在';
const pinHintMarker = 'pin-hint-shown';
const restoredSource = '之前固定的';

String _two(int n) => n.toString().padLeft(2, '0');

/// `YYYYMMDD-HHMMSS-<title>`: the title loses path and Windows-reserved characters, control
/// characters and leading dots, keeps 20 characters; an empty one becomes the kind's word. It never
/// holds `/`, `\` or a leading `.`, which the runner does not check.
String pinStem(DateTime at, String title, ClipKind kind) {
  final time = '${at.year.toString().padLeft(4, '0')}${_two(at.month)}${_two(at.day)}-'
      '${_two(at.hour)}${_two(at.minute)}${_two(at.second)}';
  var t = title.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f\x7f]'), '').trim();
  t = t.replaceFirst(RegExp(r'^[.\s]+'), '');
  t = String.fromCharCodes(t.runes.take(20)).trimRight();
  if (t.isEmpty) t = kindWord(kind);
  return '$time-$t';
}

final _stemTime = RegExp(r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-');

String _base(String path) {
  final i = path.lastIndexOf('/');
  final j = path.lastIndexOf('\\');
  return path.substring((i > j ? i : j) + 1);
}

/// Saved pins: `clipboard/*.md` and everything in `files/clipboard/`, by name.
List<String> pinnedPaths(DataDir d) {
  final out = <String>[];
  void scan(String dir, bool onlyMd) {
    try {
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final n = _base(e.path);
        if (n.startsWith('.') || n.endsWith('.tmp')) continue;
        if (onlyMd && (e is! File || !n.endsWith('.md'))) continue;
        out.add(e.path);
      }
    } catch (_) {}
  }

  scan(d.clipboardDir, true);
  scan(d.filesClipboardDir, false);
  out.sort((a, b) => _base(a).compareTo(_base(b)));
  return out;
}

/// The file's name without the time prefix and, for a file, its extension.
String pinTitle(String path) {
  var n = _base(path).replaceFirst(_stemTime, '');
  var isDir = false;
  try {
    isDir = FileSystemEntity.isDirectorySync(path);
  } catch (_) {}
  final dot = n.lastIndexOf('.');
  if (!isDir && dot > 0) n = n.substring(0, dot);
  return n;
}

/// The time in the file's name; null when it has none.
DateTime? pinTime(String path) {
  final m = _stemTime.firstMatch(_base(path));
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

/// Removes the file or folder; never throws.
void deletePin(String path) {
  try {
    final t = FileSystemEntity.typeSync(path, followLinks: false);
    if (t == FileSystemEntityType.directory) {
      Directory(path).deleteSync(recursive: true);
    } else if (t != FileSystemEntityType.notFound) {
      File(path).deleteSync();
    }
  } catch (_) {}
}
