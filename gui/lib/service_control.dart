// Start/stop/restart rapp-service with the platform's own tools (§4).
// Command construction and the plist are pure; only [ServiceController] runs anything.
import 'dart:io';

enum ServiceAction { start, stop, restart }

const serviceLabel = 'com.rapp.service';
const _winRunKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

class ShellCommand {
  const ShellCommand(this.exe, this.args, {this.detached = false});
  final String exe;
  final List<String> args;

  /// Launch and forget (Windows service start) instead of waiting for exit.
  final bool detached;

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
      return switch (action) {
        ServiceAction.start => [ShellCommand('launchctl', ['bootstrap', 'gui/$uid', launchAgentPlistPath(home)])],
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

/// LaunchAgent that keeps [serviceExe] running for the logged-in user.
String launchAgentPlist(String serviceExe, {Map<String, String> environment = const {}}) {
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
        final r = await Process.run(c.exe, c.args);
        if (r.exitCode != 0) {
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
    final content = launchAgentPlist(serviceExe,
        environment: {if (rappHome != null && rappHome.isNotEmpty) 'RAPP_HOME': rappHome});
    final f = File(launchAgentPlistPath(home));
    if (f.existsSync() && f.readAsStringSync() == content) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }
}
