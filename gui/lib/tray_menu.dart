// Tray and Dock menus: one group per host, its open sessions (marked ●) then its idle 常用.
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

/// One group per device, ordered by host name (stable). Within it the open sessions by title, each
/// marked ●, then the idle favourites in favourite order. A host's header says （离线） when its
/// favourites know it is offline; those are greyed, the sessions stay clickable.
List<MenuItem> _body(List<SessionEntry> sessions, List<MenuFavorite> favorites) {
  if (sessions.isEmpty && favorites.isEmpty) return [MenuItem(label: '没有打开的会话', disabled: true)];
  final hosts = <String, _Host>{};
  for (final g in groupSessions(sessions, Grouping.device)) {
    for (final e in g.entries) {
      hosts.putIfAbsent(e.id, () => _Host(e.device)).open.add(e);
    }
  }
  for (final f in favorites) {
    final h = hosts.putIfAbsent(f.app.device, () => _Host(f.host));
    h.idle.add(f);
    h.offline = h.offline || f.offline;
  }
  final order = hosts.values.toList();
  final at = {for (var i = 0; i < order.length; i++) order[i]: i};
  order.sort((a, b) {
    final c = a.name.compareTo(b.name);
    return c != 0 ? c : at[a]!.compareTo(at[b]!);
  });
  return [
    for (final h in order) ...[
      MenuItem(label: '${h.name}${h.offline ? '（离线）' : ''}', disabled: true),
      for (final e in h.open)
        MenuItem(
          key: '$sessionKeyPrefix${e.key}',
          label: '  ● ${e.title}${e.lamp == Lamp.disconnected ? '（已断开）' : ''}',
        ),
      for (final f in h.idle)
        MenuItem(key: '$favKeyPrefix${f.app.key}', label: '     ${f.app.name}', disabled: f.offline),
    ],
  ];
}

class _Host {
  _Host(this.name);
  final String name;
  final open = <SessionEntry>[];
  final idle = <MenuFavorite>[];
  bool offline = false;
}
