// Tray and Dock menus: the open sessions grouped by host, then the idle 常用 grouped by host.
// The tray adds 显示 rapp and 退出 around them; the Dock has its own (system) items for those.
import 'package:tray_manager/tray_manager.dart';

import 'ui/lamp.dart';
import 'ui/session_model.dart';
import 'ui/workspace_store.dart';

const sessionKeyPrefix = 'session:';
const favKeyPrefix = 'fav:';

/// The [SessionEntry.key] behind a menu item key, or null for other items.
String? sessionKeyOf(String? itemKey) =>
    itemKey != null && itemKey.startsWith(sessionKeyPrefix) ? itemKey.substring(sessionKeyPrefix.length) : null;

/// The [AppRef.key] behind a menu item key, or null for other items.
String? favKeyOf(String? itemKey) =>
    itemKey != null && itemKey.startsWith(favKeyPrefix) ? itemKey.substring(favKeyPrefix.length) : null;

/// A favourite as the menus list it: its host's name, and whether that host is offline (greyed).
class MenuFavorite {
  const MenuFavorite(this.app, {required this.host, required this.offline});
  final AppRef app;
  final String host;
  final bool offline;
}

List<MenuFavorite> menuFavorites(List<AppRef> idle,
        {required String Function(String id) hostName, required bool Function(String id) offline}) =>
    [for (final a in idle) MenuFavorite(a, host: hostName(a.device), offline: offline(a.device))];

List<MenuItem> trayItems(List<SessionEntry> sessions, {List<MenuFavorite> favorites = const []}) => [
      MenuItem(key: 'show', label: '显示 rapp'),
      MenuItem.separator(),
      ..._body(sessions, favorites),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ];

List<MenuItem> dockItems(List<SessionEntry> sessions, {List<MenuFavorite> favorites = const []}) =>
    _body(sessions, favorites);

List<MenuItem> _body(List<SessionEntry> sessions, List<MenuFavorite> favorites) {
  final groups = groupSessions(sessions, Grouping.device);
  return [
    if (groups.isEmpty) MenuItem(label: '没有打开的会话', disabled: true),
    for (final g in groups) ...[
      MenuItem(label: g.title, disabled: true),
      for (final e in g.entries)
        MenuItem(
          key: '$sessionKeyPrefix${e.key}',
          label: '    ${e.title}${e.lamp == Lamp.disconnected ? '（已断开）' : ''}',
        ),
    ],
    ..._favorites(favorites),
  ];
}

/// 常用 by host (one group per device, ordered by host name, stable), favourite order within.
List<MenuItem> _favorites(List<MenuFavorite> favorites) {
  if (favorites.isEmpty) return const [];
  final byDevice = <String, List<MenuFavorite>>{};
  for (final f in favorites) {
    byDevice.putIfAbsent(f.app.device, () => []).add(f);
  }
  final groups = byDevice.values.toList();
  final order = [for (var i = 0; i < groups.length; i++) i]
    ..sort((a, b) {
      final c = groups[a].first.host.compareTo(groups[b].first.host);
      return c != 0 ? c : a.compareTo(b);
    });
  return [
    MenuItem.separator(),
    MenuItem(label: '常用', disabled: true),
    for (final i in order) ...[
      MenuItem(label: '${groups[i].first.host}${groups[i].first.offline ? '（离线）' : ''}', disabled: true),
      for (final f in groups[i])
        MenuItem(key: '$favKeyPrefix${f.app.key}', label: '    ${f.app.name}', disabled: f.offline),
    ],
  ];
}
