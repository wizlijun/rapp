// 更改数据目录的位置 (D12): copy or adopt a new root, move the pointer, restart the service.
import 'dart:io';

import 'data_dir.dart';
import 'paths.dart';
import 'ui/main_state.dart';

enum RelocateKind { copy, adopt }

String _norm(String p) {
  final win = Platform.isWindows;
  var s = Uri.file(Directory(p).absolute.path, windows: win).normalizePath().toFilePath(windows: win);
  while (s.length > 1 && (s.endsWith('/') || s.endsWith(Platform.pathSeparator))) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// R15: what moving [from] to [to] would do; reads the disk but changes nothing.
({RelocateKind? kind, String? error}) planRelocation(String from, String to) {
  final f = _norm(from), t = _norm(to);
  if (f == t) return (kind: null, error: '已经是这个位置');
  final sep = Platform.pathSeparator;
  bool inside(String a, String b) => a.startsWith(b.endsWith(sep) ? b : '$b$sep');
  if (inside(t, f) || inside(f, t)) return (kind: null, error: '新位置不能在当前数据目录里面，也不能包着它');
  if (isRappDataDir(t)) return (kind: RelocateKind.adopt, error: null);
  final type = FileSystemEntity.typeSync(t);
  if (type == FileSystemEntityType.notFound) return (kind: RelocateKind.copy, error: null);
  if (type == FileSystemEntityType.directory) {
    try {
      if (Directory(t).listSync().isEmpty) return (kind: RelocateKind.copy, error: null);
    } catch (_) {}
  }
  return (kind: null, error: '这个文件夹里已经有别的东西，选一个空文件夹');
}

/// Copies (for [RelocateKind.copy]) and then writes, or for [isDefault] deletes, [pointer].
/// The old root is never changed. Null means success, else a short error.
Future<String?> applyRelocation({
  required String from,
  required String to,
  required RelocateKind kind,
  required String pointer,
  required bool isDefault,
  Future<ProcessResult> Function(String, List<String>) run = Process.run,
}) async {
  try {
    if (kind == RelocateKind.copy) {
      Directory(to).createSync(recursive: true);
      final r = await run('cp', ['-Rp', '$from/.', to]);
      if (r.exitCode != 0) {
        final line = r.stderr.toString().split('\n').first.trim();
        return '复制没成功：$line';
      }
    }
    if (isDefault) {
      final f = File(pointer);
      if (f.existsSync()) f.deleteSync();
    } else {
      File(pointer).parent.createSync(recursive: true);
      File(pointer).writeAsStringSync('$to\n');
    }
    return null;
  } on FileSystemException catch (e) {
    return '没改成：${e.osError?.message ?? e.message}';
  }
}

/// The whole change: pointer, service restart, hub, GUI state (R17).
class DataRelocator {
  DataRelocator({
    required this.env,
    required this.os,
    required this.restartService,
    required this.setHubHome,
    required this.state,
  });

  final Map<String, String> env;
  final String os;
  final Future<String?> Function() restartService;
  final Future<void> Function(String localDir) setHubHome;
  final MainState state;

  /// The sentence to show.
  Future<String> run(String to, {required bool isDefault}) async {
    final from = state.data.root;
    final target = _norm(to);
    final plan = planRelocation(from, target);
    if (plan.error != null) return plan.error!;
    final err = await applyRelocation(
        from: _norm(from), to: target, kind: plan.kind!, pointer: pointerFile(env, os), isDefault: isDefault);
    if (err != null) return err;
    final restartErr = await restartService();
    try {
      await setHubHome('$target/local');
    } catch (e) {
      stderr.writeln('rapp: hub set_home: $e');
    }
    state.relocate(DataDir(target));
    return restartErr == null ? '数据目录已改到 $target，服务已重启' : '数据目录已改到 $target，服务没重启成功：$restartErr';
  }
}
