// Tray menu: 显示 rapp, the open sessions grouped by host, 退出.
import 'package:tray_manager/tray_manager.dart';

import 'ui/lamp.dart';
import 'ui/session_model.dart';

const sessionKeyPrefix = 'session:';

/// The [SessionEntry.key] behind a tray item key, or null for other items.
String? sessionKeyOf(String? itemKey) =>
    itemKey != null && itemKey.startsWith(sessionKeyPrefix) ? itemKey.substring(sessionKeyPrefix.length) : null;

List<MenuItem> trayItems(List<SessionEntry> sessions) {
  final groups = groupSessions(sessions, Grouping.device);
  return [
    MenuItem(key: 'show', label: '显示 rapp'),
    MenuItem.separator(),
    if (groups.isEmpty) MenuItem(label: '没有打开的会话', disabled: true),
    for (final g in groups) ...[
      MenuItem(label: g.title, disabled: true),
      for (final e in g.entries)
        MenuItem(
          key: '$sessionKeyPrefix${e.key}',
          label: '    ${e.appName}${e.lamp == Lamp.disconnected ? '（已断开）' : ''}',
        ),
    ],
    MenuItem.separator(),
    MenuItem(key: 'quit', label: '退出'),
  ];
}
