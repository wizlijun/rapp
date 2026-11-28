/// The phone's notes for the 助理 (V1c Task 16, V7-V9): kept in `<localDir>/assistant.json`, on this phone only.
/// Nothing here touches the hub, a terminal or the network.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

const assistantFile = 'assistant.json';

class AssistantNote {
  const AssistantNote({required this.id, required this.text, required this.at, this.project});
  final String id;
  final String text;

  /// Milliseconds since the epoch.
  final int at;

  /// The project the note was made in; null when there was none (the phone has no project scope yet).
  final String? project;

  Map<String, Object?> toJson() => {'id': id, 'text': text, 'at': at, if (project != null) 'project': project};
}

class AssistantStore extends ChangeNotifier {
  /// Reads `assistant.json` in [dir] now; a missing or damaged file is an empty list.
  AssistantStore(this.dir) {
    try {
      final v = jsonDecode(File('$dir/$assistantFile').readAsStringSync());
      if (v is Map && v['notes'] is List) {
        for (final n in v['notes'] as List) {
          if (n is Map && n['id'] is String && n['text'] is String && n['at'] is int) {
            _notes.add(AssistantNote(
                id: n['id'] as String, text: n['text'] as String, at: n['at'] as int, project: n['project'] as String?));
          }
        }
      }
    } catch (_) {}
  }

  final String dir;
  final List<AssistantNote> _notes = [];
  int _n = 0;
  Future<void> _writing = Future.value();

  /// Newest first.
  List<AssistantNote> get notes => List.unmodifiable(_notes);

  Future<void> add(String text, {String? project}) {
    final t = text.trim();
    if (t.isEmpty) return Future.value();
    final at = DateTime.now().millisecondsSinceEpoch;
    _notes.insert(0, AssistantNote(id: '$at-${_n++}', text: t, at: at, project: project));
    notifyListeners();
    return _save();
  }

  Future<void> remove(String id) {
    final before = _notes.length;
    _notes.removeWhere((n) => n.id == id);
    if (_notes.length == before) return Future.value();
    notifyListeners();
    return _save();
  }

  /// Writes a temp file and renames it into place; writes go one after another. A failure is swallowed: the list
  /// on screen stays, and the next change writes again. No note text is logged.
  Future<void> _save() => _writing = _writing.then((_) async {
        final tmp = File('$dir/$assistantFile.tmp');
        try {
          await Directory(dir).create(recursive: true);
          await tmp.writeAsString(jsonEncode({'version': 1, 'notes': [for (final n in _notes) n.toJson()]}), flush: true);
          await tmp.rename('$dir/$assistantFile');
        } catch (_) {
          try {
            if (tmp.existsSync()) tmp.deleteSync();
          } catch (_) {}
        }
      });
}
