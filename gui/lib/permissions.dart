// macOS permissions A needs to share an app: names, purposes, settings links, and hints.

enum Permission {
  screenRecording('screen_recording', 'Screen Recording', '屏幕录制', '把这台电脑上 app 窗口的画面传给另一台电脑',
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'),
  accessibility('accessibility', 'Accessibility', '辅助功能', '让另一台电脑的鼠标键盘操作这里的 app，并移动窗口、使用菜单',
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility');

  const Permission(this.key, this.hostName, this.label, this.purpose, this.settingsUrl);

  /// Key in the service's `permissions` map.
  final String key;

  /// Name in rapp-host's `missing permission: …` line.
  final String hostName;
  final String label;
  final String purpose;
  final String settingsUrl;
}

/// What a `{"screen_recording":…,"accessibility":…}` map lacks; nothing when there is no map.
List<Permission> missingPermissions(Object? perms) =>
    perms is Map ? [for (final p in Permission.values) if (perms[p.key] != true) p] : const [];

/// What rapp-host's `missing permission: Screen Recording, Accessibility` names; null for other errors.
List<Permission>? missingFromError(String error) {
  const marker = 'missing permission: ';
  final at = error.indexOf(marker);
  if (at < 0) return null;
  final names = error.substring(at + marker.length).split('\n').first.split(',').map((n) => n.trim());
  final missing = [for (final p in Permission.values) if (names.contains(p.hostName)) p];
  return missing.isEmpty ? null : missing;
}

/// For B: what A lacks and where to fix it (only someone at A can).
String remoteHint(String host, List<Permission> missing) =>
    '「$host」缺少 ${missing.map((p) => p.label).join('、')} 权限。请在那台电脑上打开 rapp，在 本机 › 权限 里点「打开系统设置」。';
