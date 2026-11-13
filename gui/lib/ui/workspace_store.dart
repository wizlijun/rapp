// workspace.json: favourites and projects, kept in the GUI config dir. Pure Dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const workspaceVersion = 1;
const workspaceFile = 'workspace.json';
const loadProblem = '项目和常用没有读到，已从空白开始';

/// An app on a device, with the display name it had when it was saved.
class AppRef {
  const AppRef(this.device, this.bundle, this.name);
  final String device, bundle, name;
  String get key => '$device/$bundle';
}

class Member {
  Member(this.app, [this.task = '']);
  final AppRef app;
  String task;
  String get key => app.key;
}

class Project {
  Project(this.id, this.name, [List<Member>? members]) : members = members ?? [];
  final String id;
  String name;
  final List<Member> members;
}

/// Folds `\r` and `\n` into spaces and trims.
String oneLine(String s) => s.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();

String _str(Object? v, {bool required = false}) {
  if (v is! String || (required && v.isEmpty)) throw const FormatException('bad field');
  return v;
}

AppRef _appRef(Object? j) {
  if (j is! Map) throw const FormatException('bad entry');
  final device = _str(j['device'], required: true);
  final bundle = _str(j['bundle'], required: true);
  final name = j.containsKey('name') ? oneLine(_str(j['name'])) : bundle;
  return AppRef(device, bundle, name);
}

List<Object?> _list(Object? v) {
  if (v == null) return const [];
  if (v is! List) throw const FormatException('not a list');
  return v;
}

class Workspace {
  Workspace({List<AppRef>? favorites, List<Project>? projects})
      : favorites = favorites ?? [],
        projects = projects ?? [];
  final List<AppRef> favorites;
  final List<Project> projects;

  Map<String, Object?> toJson() => {
        'version': workspaceVersion,
        'favorites': [
          for (final f in favorites) {'device': f.device, 'bundle': f.bundle, 'name': f.name},
        ],
        'projects': [
          for (final p in projects)
            {
              'id': p.id,
              'name': p.name,
              'members': [
                for (final m in p.members)
                  {'device': m.app.device, 'bundle': m.app.bundle, 'name': m.app.name, 'task': m.task},
              ],
            },
        ],
      };

  static Workspace fromJson(Object? json) {
    if (json is! Map || json['version'] != workspaceVersion) throw const FormatException('bad workspace');
    final favorites = <AppRef>[];
    final seenFav = <String>{};
    for (final f in _list(json['favorites'])) {
      final a = _appRef(f);
      if (seenFav.add(a.key)) favorites.add(a);
    }
    final projects = <Project>[];
    final seenIds = <String>{};
    for (final p in _list(json['projects'])) {
      if (p is! Map) throw const FormatException('bad project');
      final id = _str(p['id'], required: true);
      final name = p.containsKey('name') ? oneLine(_str(p['name'])) : '';
      final members = <Member>[];
      final seenKeys = <String>{};
      for (final m in _list(p['members'])) {
        final a = _appRef(m);
        final task = (m as Map).containsKey('task') ? oneLine(_str(m['task'])) : '';
        if (seenKeys.add(a.key)) members.add(Member(a, task));
      }
      if (seenIds.add(id)) projects.add(Project(id, name, members));
    }
    return Workspace(favorites: favorites, projects: projects);
  }
}

/// Reads `dir/workspace.json`. Never throws: a missing file is empty; anything unreadable
/// starts empty, reports [loadProblem] and moves the file to `workspace.json.bad`.
({Workspace workspace, String? problem}) loadWorkspace(String dir) {
  final f = File('$dir/$workspaceFile');
  try {
    if (!f.existsSync()) return (workspace: Workspace(), problem: null);
  } catch (_) {
    return (workspace: Workspace(), problem: loadProblem);
  }
  try {
    return (workspace: Workspace.fromJson(jsonDecode(f.readAsStringSync())), problem: null);
  } catch (_) {
    try {
      f.renameSync('$dir/$workspaceFile.bad');
    } catch (_) {}
    return (workspace: Workspace(), problem: loadProblem);
  }
}

/// Writes through a temp file and a rename so a failed write leaves the old file whole.
void saveWorkspace(String dir, Workspace w) {
  Directory(dir).createSync(recursive: true);
  final tmp = File('$dir/$workspaceFile.tmp');
  try {
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(w.toJson()), flush: true);
    tmp.renameSync('$dir/$workspaceFile');
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

/// A random (version 4) UUID string.
String newProjectId([Random? rng]) {
  final r = rng ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
