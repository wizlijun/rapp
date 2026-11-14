import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/overview_model.dart';
import 'package:rapp/ui/resources_state.dart';
import 'package:rapp/ui/session_model.dart';

SessionEntry se(String id, Lamp lamp, {String app = 'a', String path = ''}) => SessionEntry(
    sid: 1, id: id, app: app, appName: app, device: id, path: path, lamp: lamp);

ClipEntry clip(int n, {bool pinned = false}) =>
    ClipEntry(n, 'k', 1, n, ClipKind.text, 't', 's', DateTime(2026))..pinned = pinned;

TransferRow tr(bool down, String name, int done, int total) =>
    TransferRow(1, 1, 1, 'k', down, name, 's', done, total, TransferState.running);

void main() {
  test('counts each lamp', () {
    final c = overviewCounts(
        [for (final l in [Lamp.active, Lamp.active, Lamp.idle, Lamp.connecting, Lamp.disconnected]) se('m', l)],
        online: 2, devices: 3);
    expect((c.active, c.idle, c.connecting, c.disconnected, c.waiting), (2, 1, 1, 1, 0));
    expect((c.online, c.devices), (2, 3));
  });

  test('waiting is counted when present', () {
    final c = overviewCounts([se('m', Lamp.waiting), se('m', Lamp.offline), se('m', Lamp.notOpened)],
        online: 1, devices: 1);
    expect(c.waiting, 1);
    expect(c.active + c.idle + c.connecting + c.disconnected, 0);
  });

  test('columns: local first, then hosts in add order, offline hosts too', () {
    final cols = deviceColumns(
      hosts: const [HubHost('m1', 'A'), HubHost('m2', 'B'), HubHost('m3', 'C')],
      probes: {'m1': DeviceProbe(Lamp.active, '在线'), 'm2': DeviceProbe(Lamp.offline, '离线')},
      entries: [],
      name: (id) => id,
    );
    expect(cols.map((c) => c.id), [null, 'm1', 'm2', 'm3']);
    expect(cols[0].name, '本机');
    expect(cols[0].entries, isEmpty);
    expect(cols[0].lamp, Lamp.active);
    expect(cols[0].word, '在线');
    expect(cols[2].offline, isTrue);
    expect(cols[2].word, '离线');
    expect(cols[3].lamp, Lamp.connecting);
    expect(cols[3].word, '连接中');
  });

  test('sessions on an unknown device get their own column', () {
    final cols = deviceColumns(
      hosts: const [HubHost('m1', 'A')],
      probes: {'m1': DeviceProbe(Lamp.active, '在线')},
      entries: [se('gone', Lamp.disconnected)],
      name: (id) => 'N-$id',
    );
    expect(cols.last.id, 'gone');
    expect(cols.last.name, 'N-gone');
    expect(cols.last.offline, isTrue);
    expect(cols.last.word, '离线');
  });

  test('every entry lands in exactly one column', () {
    final es = [
      se('m1', Lamp.active, app: '1'),
      se('gone', Lamp.idle, app: '2'),
      se('m2', Lamp.idle, app: '3'),
      se('m1', Lamp.idle, app: '4'),
      se('gone', Lamp.idle, app: '5'),
      se('m2', Lamp.active, app: '6'),
    ];
    final cols = deviceColumns(
      hosts: const [HubHost('m1', 'A'), HubHost('m2', 'B')],
      probes: const {},
      entries: es,
      name: (id) => id,
    );
    expect(cols.map((c) => c.id), [null, 'm1', 'm2', 'gone']);
    expect(cols.expand((c) => c.entries).length, 6);
    expect(cols.expand((c) => c.entries).toSet(), es.toSet());
    expect(cols[1].entries.map((e) => e.app), ['1', '4']);
    expect(cols[3].entries.map((e) => e.app), ['2', '5']);
  });

  test('column path comes from its sessions and is empty without them', () {
    final cols = deviceColumns(
      hosts: const [HubHost('m1', 'A'), HubHost('m2', 'B')],
      probes: {'m1': DeviceProbe(Lamp.active, '在线')},
      entries: [se('m1', Lamp.active, path: ''), se('m1', Lamp.active, path: 'lan')],
      name: (id) => id,
    );
    expect(cols[1].path, '局域网');
    expect(cols[2].path, '');
    expect(cols[0].path, '');
  });

  test('windows word only from two', () {
    expect(windowsWord(0), isNull);
    expect(windowsWord(1), isNull);
    expect(windowsWord(2), '2 个窗口');
  });

  test('clip summary', () {
    expect(clipSummary([]), '还没有剪贴板条目');
    expect(clipSummary([for (var i = 0; i < 3; i++) clip(i)]), '剪贴板 3 条');
    expect(clipSummary([for (var i = 0; i < 12; i++) clip(i, pinned: i < 3)]), '剪贴板 12 条，固定 3 条');
  });

  test('transfer summary', () {
    expect(transferSummary([]), '没有进行中的传输');
    expect(transferSummary([tr(true, 'app.log', 429, 1000)]), '下载 app.log 42%');
    expect(transferSummary([tr(false, 'x.txt', 0, 0)]), '上传 x.txt 0%');
    expect(transferSummary([tr(true, 'a', 1, 2), tr(true, 'b', 1, 2), tr(false, 'c', 1, 2)]), '3 个传输');
  });
}
