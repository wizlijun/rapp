// 本机 › 权限: one row per macOS permission with its purpose, ✓ or 「打开系统设置」.
import 'dart:io';

import 'package:flutter/material.dart';

import '../permissions.dart';

class PermissionsPanel extends StatelessWidget {
  const PermissionsPanel({super.key, required this.permissions, required this.onOpenSettings});

  /// The service's `{"screen_recording","accessibility"}`.
  final Map<String, dynamic> permissions;
  final Future<void> Function(Permission) onOpenSettings;

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
      if (missing.isNotEmpty) Text('授权后这里会自动变成 ✓；如果一直不变，点下面的「重启」。', style: grey),
    ]);
  }
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
