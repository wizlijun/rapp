// Overview (全景) model: counts, device columns, window word and resource sentences. Pure Dart.
import '../hub_client.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'resources_state.dart';
import 'session_model.dart';

typedef OverviewCounts = ({int active, int idle, int connecting, int disconnected, int waiting, int online, int devices});

/// Sessions counted by lamp (K1); offline and not-opened rows do not count.
OverviewCounts overviewCounts(List<SessionEntry> entries, {required int online, required int devices}) {
  int n(Lamp l) => entries.where((e) => e.lamp == l).length;
  return (
    active: n(Lamp.active),
    idle: n(Lamp.idle),
    connecting: n(Lamp.connecting),
    disconnected: n(Lamp.disconnected),
    waiting: n(Lamp.waiting),
    online: online,
    devices: devices,
  );
}

class DeviceColumn {
  const DeviceColumn({
    required this.id,
    required this.name,
    required this.lamp,
    required this.word,
    required this.path,
    required this.entries,
  });

  /// null = this Mac.
  final String? id;
  final String name;
  final Lamp lamp;
  final String word;

  /// Path word of the first session that has one, or ''.
  final String path;
  final List<SessionEntry> entries;

  bool get offline => lamp == Lamp.offline;
}

/// This Mac, then [hosts] in order, then devices that only sessions know about (C3).
List<DeviceColumn> deviceColumns({
  required List<HubHost> hosts,
  required Map<String, DeviceProbe> probes,
  required List<SessionEntry> entries,
  required String Function(String id) name,
}) {
  String pathOf(List<SessionEntry> es) {
    for (final e in es) {
      final p = pathLabels[e.path];
      if (p != null) return p;
    }
    return '';
  }

  List<SessionEntry> of(String id) => [for (final e in entries) if (e.id == id) e];

  final cols = <DeviceColumn>[
    const DeviceColumn(id: null, name: '本机', lamp: Lamp.active, word: '在线', path: '', entries: []),
  ];
  final known = <String>{};
  for (final h in hosts) {
    if (!known.add(h.id)) continue;
    final p = probes[h.id];
    final es = of(h.id);
    cols.add(DeviceColumn(
      id: h.id,
      name: h.name,
      lamp: p?.lamp ?? Lamp.connecting,
      word: p?.word ?? '连接中',
      path: pathOf(es),
      entries: es,
    ));
  }
  for (final e in entries) {
    if (!known.add(e.id)) continue;
    final p = probes[e.id];
    final es = of(e.id);
    cols.add(DeviceColumn(
      id: e.id,
      name: name(e.id),
      lamp: p?.lamp ?? Lamp.offline,
      word: p?.word ?? '离线',
      path: pathOf(es),
      entries: es,
    ));
  }
  return cols;
}

/// K2: only from two windows on.
String? windowsWord(int n) => n >= 2 ? '$n 个窗口' : null;

/// Count only; never titles or contents (C8).
String clipSummary(List<ClipEntry> clips) {
  if (clips.isEmpty) return '还没有剪贴板条目';
  final pinned = clips.where((c) => c.pinned).length;
  return pinned == 0 ? '剪贴板 ${clips.length} 条' : '剪贴板 ${clips.length} 条，固定 $pinned 条';
}

String transferSummary(List<TransferRow> running) {
  if (running.isEmpty) return '没有进行中的传输';
  if (running.length > 1) return '${running.length} 个传输';
  final t = running.single;
  final pct = t.total > 0 ? t.done * 100 ~/ t.total : 0;
  return '${t.down ? '下载' : '上传'} ${t.name} $pct%';
}
