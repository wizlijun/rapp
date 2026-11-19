import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/tray_menu.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/session_model.dart';
import 'package:rapp/ui/workspace_store.dart';

SessionEntry e(String id, String device, String app, {Lamp lamp = Lamp.active}) => SessionEntry(
      sid: 1, id: id, app: app, appName: app, device: device, path: 'lan', lamp: lamp);

MenuFavorite f(String id, String host, String bundle, {bool offline = false}) =>
    MenuFavorite(AppRef(id, bundle, bundle), host: host, offline: offline);

void main() {
  test('no sessions: one disabled hint between show and quit', () {
    final items = trayItems(const []);
    expect(items.first.key, 'show');
    expect(items.last.key, 'quit');
    final hint = items.singleWhere((i) => i.label == '没有打开的会话');
    expect(hint.disabled, isTrue);
  });

  test('sessions are grouped under a disabled host header, sorted', () {
    final items = trayItems([e('2', 'mini', 'Safari'), e('1', 'air', 'Notes'), e('2', 'mini', 'Calculator')]);
    final labels = [for (final i in items) if (i.type != 'separator') i.label];
    expect(labels, ['显示 rapp', 'air', '    Notes', 'mini', '    Calculator', '    Safari', '退出']);
    expect(items.firstWhere((i) => i.label == 'mini').disabled, isTrue);
    expect(items.firstWhere((i) => i.label == '    Safari').key, '${sessionKeyPrefix}2/Safari');
  });

  test('a disconnected session says so', () {
    final items = trayItems([e('1', 'air', 'Notes', lamp: Lamp.disconnected)]);
    expect(items.any((i) => i.label == '    Notes（已断开）'), isTrue);
  });

  test('sessionKeyOf reads back the entry key, null for others', () {
    expect(sessionKeyOf('${sessionKeyPrefix}2/Safari'), '2/Safari');
    expect(sessionKeyOf('quit'), isNull);
  });
  test('favourites follow the sessions under 常用, grouped by host name, favourite order kept', () {
    final items = trayItems([e('1', 'air', 'Notes')],
        favorites: [f('2', 'mini', 'Xcode'), f('1', 'air', 'Mail'), f('2', 'mini', 'Pages')]);
    final labels = [for (final i in items) if (i.type != 'separator') i.label];
    expect(labels, ['显示 rapp', 'air', '    Notes', '常用', 'air', '    Mail', 'mini', '    Xcode', '    Pages', '退出']);
    expect(items.firstWhere((i) => i.label == '常用').disabled, isTrue);
    expect(items.firstWhere((i) => i.label == '    Xcode').key, '${favKeyPrefix}2/Xcode');
    expect(items.firstWhere((i) => i.label == '    Xcode').disabled, isFalse);
  });

  test('an offline host says so and its favourites are greyed', () {
    final items = trayItems(const [], favorites: [f('2', 'mini', 'Xcode', offline: true)]);
    expect(items.firstWhere((i) => i.label == 'mini（离线）').disabled, isTrue);
    expect(items.firstWhere((i) => i.label == '    Xcode').disabled, isTrue);
  });

  test('two devices with the same name stay two groups', () {
    final items = trayItems(const [], favorites: [f('1', 'mini', 'A'), f('2', 'mini', 'B'), f('1', 'mini', 'C')]);
    final labels = [for (final i in items) if (i.type != 'separator') i.label];
    expect(labels, ['显示 rapp', '没有打开的会话', '常用', 'mini', '    A', '    C', 'mini', '    B', '退出']);
  });

  test('no idle favourites: no 常用 section and no extra separator', () {
    final items = trayItems([e('1', 'air', 'Notes')]);
    expect(items.any((i) => i.label == '常用'), isFalse);
    expect(items.where((i) => i.type == 'separator').length, 2);
  });

  test('the dock menu is the tray menu without 显示 rapp, 退出 and their separators', () {
    final items = dockItems([e('1', 'air', 'Notes')], favorites: [f('2', 'mini', 'Xcode')]);
    final shape = [for (final i in items) i.type == 'separator' ? '—' : i.label];
    expect(shape, ['air', '    Notes', '—', '常用', 'mini', '    Xcode']);
    expect(dockItems(const []).map((i) => i.label), ['没有打开的会话']);
  });

  test('favKeyOf reads back the favourite key, null for others', () {
    expect(favKeyOf('${favKeyPrefix}2/Xcode'), '2/Xcode');
    expect(favKeyOf('${sessionKeyPrefix}2/Xcode'), isNull);
    expect(favKeyOf(null), isNull);
  });

  test('menuFavorites names each host and marks offline ones', () {
    final m = menuFavorites([const AppRef('2', 'Xcode', 'Xcode')],
        hostName: (id) => 'mini-$id', offline: (id) => id == '2');
    expect(m.single.host, 'mini-2');
    expect(m.single.offline, isTrue);
    expect(m.single.app.key, '2/Xcode');
  });
}
