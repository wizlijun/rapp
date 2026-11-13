// Where rapp keeps its config (§3) and where it finds its sibling binaries.
import 'dart:convert';
import 'dart:io';

String? _v(Map<String, String> env, String k) => (env[k] == null || env[k]!.isEmpty) ? null : env[k];

String _userDir(Map<String, String> env, String os) => _v(env, os == 'windows' ? 'USERPROFILE' : 'HOME') ?? '.';

/// The old per-platform config dir; ignores `RAPP_HOME`. `os` is a [Platform.operatingSystem] value.
String platformConfigDir(Map<String, String> env, String os) {
  final user = _userDir(env, os);
  switch (os) {
    case 'macos':
      return '$user/Library/Application Support/rapp';
    case 'windows':
      return '${_v(env, 'APPDATA') ?? user}\\rapp';
    default:
      return '${_v(env, 'XDG_CONFIG_HOME') ?? '$user/.config'}/rapp';
  }
}

/// Where an upgrade copies old data from (R2): `RAPP_HOME`, else [platformConfigDir].
String legacyDir(Map<String, String> env, String os) => _v(env, 'RAPP_HOME') ?? platformConfigDir(env, os);

/// The data-root pointer file, kept in the platform config dir.
String pointerFile(Map<String, String> env, String os) =>
    '${platformConfigDir(env, os)}${os == 'windows' ? '\\' : '/'}data-root';

/// `~/rapp` (`%USERPROFILE%\rapp` on Windows).
String defaultDataRoot(Map<String, String> env, String os) =>
    '${_userDir(env, os)}${os == 'windows' ? '\\' : '/'}rapp';

/// The file's text, or null when it cannot be read.
String? readFileOrNull(String path) {
  try {
    return File(path).readAsStringSync();
  } catch (_) {
    return null;
  }
}

/// First line, trimmed; only an absolute path (`/…`, `\\…`, `X:\…`, `X:/…`) counts (R6).
String? _parsePointer(String text) {
  final nl = text.indexOf(RegExp(r'\r?\n'));
  final line = (nl < 0 ? text : text.substring(0, nl)).trim();
  final abs = line.startsWith('/') || line.startsWith(r'\\') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(line);
  return abs ? line : null;
}

/// The data root: `RAPP_HOME`, else the pointer file's path, else [defaultDataRoot] (R6).
String dataRoot(Map<String, String> env, String os, {String? Function(String path) read = readFileOrNull}) {
  final h = _v(env, 'RAPP_HOME');
  if (h != null) return h;
  final text = read(pointerFile(env, os));
  final p = text == null ? null : _parsePointer(text);
  return p ?? defaultDataRoot(env, os);
}

/// The data root's sub paths (spec §1), joined with `/`.
class DataDir {
  const DataDir(this.root);
  final String root;

  /// This device's private dir (secrets, state); never in git.
  String get localDir => '$root/local';

  /// Shared between devices; holds `workspace.json` and `apps.json`.
  String get sharedDir => '$root/shared';
  String deviceDir(String id) => '$root/devices/$id';
  String get filesDir => '$root/files';
  String get clipboardDir => '$root/clipboard';
  String get filesClipboardDir => '$root/files/clipboard';

  /// `id` in `local/service.json`; null on any problem (R22).
  String? deviceId() {
    try {
      final v = jsonDecode(File('$localDir/service.json').readAsStringSync());
      final id = v is Map ? v['id'] : null;
      return (id is String && id.isNotEmpty) ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// This device's folder for UI prefs, or null while the id is unknown.
  String? prefsDir() {
    final id = deviceId();
    return id == null ? null : deviceDir(id);
  }
}

/// Where the rapp logs go: the same rules as `rapp_net::log::log_dir` (observability spec §3).
String logDir(Map<String, String> env, String os) {
  String? v(String k) => (env[k] == null || env[k]!.isEmpty) ? null : env[k];
  final dir = v('RAPP_LOG_DIR');
  if (dir != null) return dir;
  final rappHome = v('RAPP_HOME');
  if (rappHome != null) return '$rappHome/local/logs';
  final home = v('HOME') ?? '.';
  switch (os) {
    case 'macos':
      return '$home/Library/Logs/rapp';
    case 'windows':
      return '${v('LOCALAPPDATA') ?? home}\\rapp\\logs';
    default:
      return '${v('XDG_STATE_HOME') ?? '$home/.local/state'}/rapp';
  }
}

/// `RAPP_BIN_DIR`, else the directory of the running executable
/// (on macOS `rapp.app/Contents/MacOS`).
String binDir(Map<String, String> env, String executable) {
  final d = env['RAPP_BIN_DIR'];
  if (d != null && d.isNotEmpty) return d;
  return File(executable).parent.path;
}

/// Full path of [name] in [dir] if it exists (`.exe` added on Windows).
String? findBinary(String name, String dir, String os) {
  final file = '$dir${Platform.pathSeparator}$name${os == 'windows' ? '.exe' : ''}';
  return File(file).existsSync() ? file : null;
}
