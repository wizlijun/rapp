// local/project_positions.json: where each project was left (its last session, when). Pure Dart.
import 'dart:convert';
import 'dart:io';

const positionsFile = 'project_positions.json';
const _positionsVersion = 1;

/// Where a project was left: [last] is the session key (device/bundle), [leftAt] when it was left.
class ProjectPosition {
  ProjectPosition({this.last, this.leftAt});
  String? last;
  DateTime? leftAt;
}

/// The positions of projects, keyed by project id.
class ProjectPositions {
  ProjectPositions([Map<String, ProjectPosition>? byProject]) : byProject = byProject ?? {};

  final Map<String, ProjectPosition> byProject;

  /// The position of [projectId]; one is made (empty) when there is none yet.
  ProjectPosition of(String projectId) => byProject.putIfAbsent(projectId, () => ProjectPosition());

  /// Forgets the projects that are not in [projectIds] (deleted ones).
  void dropExcept(Set<String> projectIds) => byProject.removeWhere((id, _) => !projectIds.contains(id));

  /// Never throws: a missing or corrupt file gives none, and a malformed entry is skipped.
  static ProjectPositions load(String dir) {
    final out = ProjectPositions();
    try {
      final j = jsonDecode(File('$dir/$positionsFile').readAsStringSync());
      final projects = j is Map ? j['projects'] : null;
      if (projects is! Map) return out;
      projects.forEach((id, e) {
        if (id is! String || e is! Map) return;
        final last = e['last'];
        if (last != null && last is! String) return;
        final leftAt = e['left_at'];
        out.byProject[id] = ProjectPosition(
          last: last as String?,
          leftAt: leftAt is String ? DateTime.tryParse(leftAt)?.toUtc() : null,
        );
      });
    } catch (_) {
      return ProjectPositions();
    }
    return out;
  }

  /// Synchronous; creates [dir] if needed. Writes a temp file and renames it into place.
  /// Throws [FileSystemException].
  void save(String dir) {
    Directory(dir).createSync(recursive: true);
    final tmp = File('$dir/$positionsFile.tmp');
    final projects = <String, Object>{
      for (final e in byProject.entries)
        e.key: {
          if (e.value.last != null) 'last': e.value.last!,
          if (e.value.leftAt != null) 'left_at': e.value.leftAt!.toUtc().toIso8601String(),
        },
    };
    try {
      tmp.writeAsStringSync(
        jsonEncode({'version': _positionsVersion, 'projects': projects}),
        flush: true,
      );
      tmp.renameSync('$dir/$positionsFile');
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }
}
