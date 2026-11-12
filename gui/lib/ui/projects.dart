// 全部打开 / 全部结束 for a project (S5 K11, K12): the plan and the hint words. Pure Dart.
import 'lamp.dart';
import 'workspace_store.dart';

/// What 「全部打开」 does with a project's members.
class OpenPlan {
  const OpenPlan(this.open, this.first, this.skipped);

  /// Members to open or reconnect, in member order.
  final List<Member> open;

  /// The key of the first member not skipped (open already or about to be): where it stops.
  final String? first;

  /// Device id → members skipped on it, in the order the devices first appear.
  final Map<String, int> skipped;
}

/// Connecting or live members count as open; the rest open (or reconnect) unless their device
/// is [offline], when they are skipped (K11).
OpenPlan planOpenAll(
  Project p, {
  required Lamp? Function(String key) lampOf,
  required bool Function(String device) offline,
}) {
  final open = <Member>[];
  String? first;
  final skipped = <String, int>{};
  for (final m in p.members) {
    final l = lampOf(m.key);
    if (l != null && l != Lamp.disconnected && l != Lamp.notOpened) {
      first ??= m.key;
    } else if (offline(m.app.device)) {
      skipped.update(m.app.device, (n) => n + 1, ifAbsent: () => 1);
    } else {
      first ??= m.key;
      open.add(m);
    }
  }
  return OpenPlan(open, first, skipped);
}

String openAllHint(Project p, OpenPlan plan, String Function(String id) deviceName) {
  if (p.members.isEmpty) return '${p.name}：没有成员';
  final parts = [
    if (plan.open.isNotEmpty) '打开 ${plan.open.length} 个',
    for (final e in plan.skipped.entries) '${deviceName(e.key)} 离线，跳过 ${e.value} 个',
  ];
  return '${p.name}：${parts.isEmpty ? '已经全部打开' : parts.join('；')}';
}

/// [shared] of the [ended] sessions are also members of another project.
String endAllHint(String name, int ended, int shared) {
  if (ended == 0) return '$name：没有要结束的会话';
  return '$name：结束 $ended 个会话${shared > 0 ? '，其中 $shared 个也属于别的项目' : ''}';
}
