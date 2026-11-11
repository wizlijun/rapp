// 本机 › 权限: one row per macOS permission with its purpose, ✓ or 「打开系统设置」.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../permissions.dart';

class PermissionsPanel extends StatelessWidget {
  const PermissionsPanel(
      {super.key, required this.permissions, required this.onOpenSettings, this.restartLabel = '重启'});

  /// The service's `{"screen_recording","accessibility"}`.
  final Map<String, dynamic> permissions;
  final Future<void> Function(Permission) onOpenSettings;

  /// The nearby button that restarts rapp-service, named in the footnote.
  final String restartLabel;

  @override
  Widget build(BuildContext context) {
    final missing = missingPermissions(permissions);
    final grey = TextStyle(color: Theme.of(context).hintColor, fontSize: 12);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (final p in Permission.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.label),
                Text(p.purpose, style: grey),
              ]),
            ),
            const SizedBox(width: 8),
            missing.contains(p)
                ? OutlinedButton(onPressed: () => onOpenSettings(p), child: const Text('打开系统设置'))
                : const Icon(Icons.check_circle, color: Colors.green),
          ]),
        ),
      if (missing.isNotEmpty) Text('授权后这里会自动变成 ✓；如果一直不变，点「$restartLabel」。', style: grey),
    ]);
  }
}

/// First-run guide on A: the panel, plus 稍后 / 重启服务 / 完成 (完成 only once nothing is missing).
class PermissionGuideDialog extends StatelessWidget {
  const PermissionGuideDialog({super.key, required this.permissions, required this.onOpenSettings, this.onRestart});

  /// Null while the service is not running.
  final Map<String, dynamic>? permissions;
  final Future<void> Function(Permission) onOpenSettings;
  final Future<void> Function()? onRestart;

  @override
  Widget build(BuildContext context) {
    final perms = permissions;
    final missing = perms == null || missingPermissions(perms).isNotEmpty;
    return AlertDialog(
      title: const Text('让另一台电脑使用这台电脑上的 app'),
      content: SizedBox(
        width: 420,
        child: perms == null
            ? const Text('服务未运行')
            : PermissionsPanel(permissions: perms, onOpenSettings: onOpenSettings, restartLabel: '重启服务'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('稍后')),
        if (missing && onRestart != null) TextButton(onPressed: onRestart, child: const Text('重启服务')),
        FilledButton(onPressed: missing ? null : () => Navigator.pop(context), child: const Text('完成')),
      ],
    );
  }
}

/// Asks macOS (through the service) first so rapp is already listed, but never holds the pane up
/// for more than [wait]: a slow or failed prompt still opens System Settings.
Future<void> promptThenOpen(Future<void> Function() prompt, Future<void> Function() open,
    {Duration wait = const Duration(seconds: 2)}) async {
  try {
    await prompt().timeout(wait);
  } catch (_) {
    // The pane still lets the user add rapp by hand.
  }
  await open();
}

/// True the first time it is called for [configDir] (it leaves a marker file), false after.
bool claimPermissionGuide(String configDir) {
  final f = File('$configDir${Platform.pathSeparator}permission-guide-shown');
  if (f.existsSync()) return false;
  try {
    f.createSync(recursive: true);
  } catch (_) {
    // Unwritable config dir: still show the guide this once.
  }
  return true;
}

/// Opens System Settings at [p]'s privacy pane.
Future<void> openSettingsPane(Permission p) async {
  await Process.run('open', [p.settingsUrl]);
}
