// 全部打开 / 全部结束 for a project (S5 K11, K12): the plan and the hint words. Pure Dart.
import 'lamp.dart';
import 'session_model.dart';
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

/// The top bar's second line for a session that is in a project (K16); null when it is in none.
/// The [current] project comes first when the session is in it.
String? projectSubtitle(SessionEntry e, List<Project> projects, {String? current}) {
  final mine = [for (final p in projects) if (p.members.any((m) => m.key == e.key)) p];
  final i = mine.indexWhere((p) => p.id == current);
  if (i > 0) mine.insert(0, mine.removeAt(i));
  if (mine.isEmpty) return null;
  String task = '';
  for (final p in mine) {
    task = p.members.firstWhere((m) => m.key == e.key).task;
    if (task.isNotEmpty) break;
  }
  return '${e.device} · ${mine.first.name}${mine.length > 1 ? '等' : ''}${task.isEmpty ? '' : ' · $task'}';
}

/// Where to stop on switching to [p]: [last] if it is still a member and open, else the first open
/// member; null when none is open.
String? resumeKey(Project p, String? last, bool Function(String key) isOpen) {
  if (last != null && p.members.any((m) => m.key == last) && isOpen(last)) return last;
  for (final m in p.members) {
    if (isOpen(m.key)) return m.key;
  }
  return null;
}

/// The cue shown on coming back to a project; null when it should not show.
String? returnCue({required DateTime? leftAt, required DateTime now, required int needs, required int disconnected}) {
  if (leftAt == null) return null;
  final ago = now.difference(leftAt);
  if (ago < const Duration(seconds: 60)) return null;
  final time = ago.inMinutes < 60
      ? '${ago.inMinutes} 分钟前离开'
      : ago.inHours < 24
          ? '${ago.inHours} 小时前离开'
          : '${ago.inDays} 天前离开';
  final changes = [if (needs > 0) '$needs 个等你', if (disconnected > 0) '$disconnected 个已断开'];
  return changes.isEmpty ? time : '$time · 这期间 ${changes.join('、')}';
}

/// Pinned projects first, the rest after; each keeps its own order.
List<Project> orderedProjects(List<Project> all) =>
    [for (final p in all) if (p.pinned) p, for (final p in all) if (!p.pinned) p];

/// The keys of [p]'s members, in member order.
List<String> projectKeys(Project p) => [for (final m in p.members) m.key];
