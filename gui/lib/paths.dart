// Where rapp keeps its config (§3) and where it finds its sibling binaries.
import 'dart:io';

/// `os` is a [Platform.operatingSystem] value.
String configDir(Map<String, String> env, String os) {
  final override = env['RAPP_HOME'];
  if (override != null && override.isNotEmpty) return override;
  final home = env['HOME'] ?? '';
  switch (os) {
    case 'macos':
      return '$home/Library/Application Support/rapp';
    case 'windows':
      return '${env['APPDATA'] ?? ''}\\rapp';
    default:
      final xdg = env['XDG_CONFIG_HOME'];
      return (xdg != null && xdg.isNotEmpty) ? '$xdg/rapp' : '$home/.config/rapp';
  }
}

/// Where the rapp logs go: the same rules as `rapp_net::log::log_dir` (observability spec §3).
String logDir(Map<String, String> env, String os) {
  String? v(String k) => (env[k] == null || env[k]!.isEmpty) ? null : env[k];
  final dir = v('RAPP_LOG_DIR');
  if (dir != null) return dir;
  final rappHome = v('RAPP_HOME');
  if (rappHome != null) return '$rappHome/logs';
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
