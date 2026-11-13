import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/tray_menu.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/session_model.dart';

SessionEntry e(String id, String device, String app, {Lamp lamp = Lamp.active}) => SessionEntry(
      sid: 1, id: id, app: app, appName: app, device: device, path: 'lan', lamp: lamp);

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
}
