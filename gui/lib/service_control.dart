// Start/stop/restart rapp-service with the platform's own tools (§4).
// Command construction and the plist are pure; only [ServiceController] runs anything.
import 'dart:io';

import 'paths.dart';

enum ServiceAction { start, stop, restart }

const serviceLabel = 'com.rapp.service';
const _winRunKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

class ShellCommand {
  const ShellCommand(this.exe, this.args, {this.detached = false, this.check = true, this.retries = 1});
  final String exe;
  final List<String> args;

  /// Launch and forget (Windows service start) instead of waiting for exit.
  final bool detached;

  /// Ignore the exit code (launchctl print as a readiness probe).
  final bool check;

  /// Run again with a 1 s pause after a nonzero exit (launchd teardown race).
  final int retries;

  @override
  String toString() => [exe, ...args].join(' ');
}

String launchAgentPlistPath(String home) => '$home/Library/LaunchAgents/$serviceLabel.plist';

List<ShellCommand> serviceCommands(
  ServiceAction action, {
  required String os,
  required int uid,
  required String home,
  required String serviceExe,
}) {
  switch (os) {
    case 'macos':
      // bootstrap right after bootout fails with "Bootstrap failed: 5: Input/output error"
      // while launchd is still tearing the old agent down (same race the pkg postinstall hit).
      // 先 bootout 清掉可能残留的旧注册，等它退出（print 探测，失败不阻断），再 bootstrap；
      // launchd 拆卸慢时 bootstrap 会报 5，隔 1 秒重试最多 5 次。
      return switch (action) {
        ServiceAction.start => [
          ShellCommand('launchctl', ['bootout', 'gui/$uid/$serviceLabel']),
          ShellCommand('launchctl', ['print', 'gui/$uid/$serviceLabel'], check: false),
          ShellCommand('launchctl', ['bootstrap', 'gui/$uid', launchAgentPlistPath(home)], retries: 5),
        ],
        ServiceAction.stop => [ShellCommand('launchctl', ['bootout', 'gui/$uid/$serviceLabel'])],
        ServiceAction.restart => [ShellCommand('launchctl', ['kickstart', '-k', 'gui/$uid/$serviceLabel'])],
      };
    case 'windows':
      final exeName = serviceExe.split(RegExp(r'[\\/]')).last;
      final stop = ShellCommand('taskkill', ['/IM', exeName, '/F']);
      final start = [
        ShellCommand('reg', ['add', _winRunKey, '/v', 'rapp-service', '/t', 'REG_SZ', '/d', '"$serviceExe"', '/f']),
        ShellCommand(serviceExe, const [], detached: true),
      ];
      return switch (action) {
        ServiceAction.start => start,
        ServiceAction.stop => [stop],
        ServiceAction.restart => [stop, start.last],
      };
    default:
      return [ShellCommand('systemctl', ['--user', action.name, 'rapp-service.service'])];
  }
}

String _xml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// Shows [dir] in the platform's file manager (「打开日志文件夹」).
/// Creates [path] if needed and makes it owner-only (observability spec §3: logs are 0700).
String ensurePrivateDir(String path) {
  Directory(path).createSync(recursive: true);
  if (!Platform.isWindows) Process.runSync('chmod', ['700', path]);
  return path;
}

ShellCommand openFolderCommand(String dir, String os) => switch (os) {
      'macos' => ShellCommand('open', [dir]),
      'windows' => ShellCommand('explorer', [dir]),
      _ => ShellCommand('xdg-open', [dir]),
    };

/// LaunchAgent that keeps [serviceExe] running for the logged-in user; with [logPath],
/// launchd sends the service's stdout and stderr there.
String launchAgentPlist(String serviceExe, {Map<String, String> environment = const {}, String? logPath}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>')
    ..writeln('\t<key>Label</key>')
    ..writeln('\t<string>$serviceLabel</string>')
    ..writeln('\t<key>ProgramArguments</key>')
    ..writeln('\t<array>')
    ..writeln('\t\t<string>${_xml(serviceExe)}</string>')
    ..writeln('\t</array>');
  if (environment.isNotEmpty) {
    b
      ..writeln('\t<key>EnvironmentVariables</key>')
      ..writeln('\t<dict>');
    for (final e in environment.entries) {
      b
        ..writeln('\t\t<key>${_xml(e.key)}</key>')
        ..writeln('\t\t<string>${_xml(e.value)}</string>');
    }
    b.writeln('\t</dict>');
  }
  if (logPath != null) {
    for (final k in ['StandardOutPath', 'StandardErrorPath']) {
      b
        ..writeln('\t<key>$k</key>')
        ..writeln('\t<string>${_xml(logPath)}</string>');
    }
  }
  b
    ..writeln('\t<key>RunAtLoad</key>')
    ..writeln('\t<true/>')
    ..writeln('\t<key>KeepAlive</key>')
    ..writeln('\t<true/>')
    ..writeln('</dict>')
    ..writeln('</plist>');
  return b.toString();
}

/// Runs the commands for real. Used only by the 启动/停止/重启 buttons.
class ServiceController {
  ServiceController({required this.serviceExe, required this.env});
  final String serviceExe;
  final Map<String, String> env;

  /// Returns null on success, else a short error text.
  Future<String?> run(ServiceAction action) async {
    final os = Platform.operatingSystem;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    var uid = 0;
    if (os == 'macos') {
      uid = int.tryParse((await Process.run('id', ['-u'])).stdout.toString().trim()) ?? 0;
      if (action == ServiceAction.start) _writePlist(home);
    }
    for (final c in serviceCommands(action, os: os, uid: uid, home: home, serviceExe: serviceExe)) {
      try {
        if (c.detached) {
          await Process.start(c.exe, c.args, mode: ProcessStartMode.detached);
          continue;
        }
        var r = await Process.run(c.exe, c.args);
        for (var n = 1; r.exitCode != 0 && n < c.retries; n++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          r = await Process.run(c.exe, c.args);
        }
        if (r.exitCode != 0 && c.check) {
          final msg = '${r.stderr}'.trim();
          return '$c → exit ${r.exitCode}${msg.isEmpty ? '' : ': $msg'}';
        }
      } on ProcessException catch (e) {
        return '$c: ${e.message}';
      }
    }
    return null;
  }

  /// The GUI owns the plist (§4); rewrite it when the bundle moved.
  void _writePlist(String home) {
    final rappHome = env['RAPP_HOME'];
    // launchd opens the log before the service runs, so its folder must already exist.
    final logs = Directory(ensurePrivateDir(logDir({...env, 'HOME': home}, 'macos')));
    final content = launchAgentPlist(serviceExe,
        environment: {if (rappHome != null && rappHome.isNotEmpty) 'RAPP_HOME': rappHome},
        logPath: '${logs.path}/launchd.log');
    final f = File(launchAgentPlistPath(home));
    if (f.existsSync() && f.readAsStringSync() == content) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }
}
