// Session list model: entries, grouping, prev/next stepping.
import 'lamp.dart';
import 'workspace_store.dart';

const pathLabels = {'lan': '局域网', 'direct': '直连', 'relay': '中继'};

/// The label of [path]; 「中继（强制）」 when the host is forced onto a relay it is on. Unknown → ''.
String routeWord(String? path, {bool forced = false}) =>
    forced && path == 'relay' ? '中继（强制）' : (pathLabels[path] ?? '');

class SessionEntry {
  const SessionEntry({
    required this.sid,
    required this.id,
    required this.app,
    required this.appName,
    required this.device,
    required this.path,
    required this.lamp,
    this.bytesPerSecond,
    this.reason,
    this.takenOver = false,
  });

  /// Disconnected because another device took it over: the button says 「拿回来」.
  final bool takenOver;

  /// null while the open request is still in flight (lamp = connecting).
  final Object? sid;
  final String id;
  final String app;
  final String appName;
  final String device;
  final String path;
  final Lamp lamp;

  /// Bytes received in the last second; only on a live embedded session.
  final int? bytesPerSecond;

  /// Why it disconnected, in words; only on a disconnected embedded session.
  final String? reason;

  String get key => '$id/$app';
}

/// The open button's word for a row in [lamp]'s state (K10).
String openVerb(Lamp? lamp, {bool takenOver = false}) => switch (lamp) {
      null || Lamp.notOpened => '打开',
      Lamp.disconnected => takenOver ? '拿回来' : '重连',
      _ => '切到',
    };

enum Grouping { device, app, project }

String groupingLabel(Grouping g) => switch (g) {
      Grouping.device => '按设备',
      Grouping.app => '按 App',
      Grouping.project => '按项目',
    };

class SessionGroup {
  const SessionGroup(this.title, this.entries);
  final String title;
  final List<SessionEntry> entries;
}

const otherGroupTitle = '其他';

/// [all] sorted by device, then app name; stable.
List<SessionEntry> _byDeviceThenApp(List<SessionEntry> all) {
  // Stable sort via original-index tiebreak.
  final indexed = [for (var i = 0; i < all.length; i++) (i, all[i])];
  indexed.sort((a, b) {
    var c = a.$2.device.compareTo(b.$2.device);
    if (c == 0) c = a.$2.appName.compareTo(b.$2.appName);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final (_, e) in indexed) e];
}

/// By project, a session in several projects appears in each (K15); [projects] is in order.
List<SessionGroup> groupSessions(List<SessionEntry> all, Grouping g, {List<Project> projects = const []}) {
  if (g == Grouping.project) {
    final byKey = {for (final e in all) e.key: e};
    final inProject = <String>{};
    final groups = <SessionGroup>[];
    for (final p in projects) {
      final es = [for (final m in p.members) ?byKey[m.key]];
      if (es.isEmpty) continue;
      inProject.addAll(es.map((e) => e.key));
      groups.add(SessionGroup(p.name, es));
    }
    final rest = _byDeviceThenApp([for (final e in all) if (!inProject.contains(e.key)) e]);
    if (rest.isNotEmpty) groups.add(SessionGroup(otherGroupTitle, rest));
    return groups;
  }
  String titleOf(SessionEntry e) => g == Grouping.device ? e.device : e.appName;
  final byTitle = <String, List<SessionEntry>>{};
  for (final e in _byDeviceThenApp(all)) {
    byTitle.putIfAbsent(titleOf(e), () => []).add(e);
  }
  final titles = byTitle.keys.toList()..sort();
  return [for (final t in titles) SessionGroup(t, byTitle[t]!)];
}

String? stepKey(List<SessionGroup> groups, String? current, int delta) {
  final keys = {for (final g in groups) for (final e in g.entries) e.key}.toList();
  if (keys.isEmpty) return null;
  final i = current == null ? -1 : keys.indexOf(current);
  if (i < 0) return keys.first;
  return keys[((i + delta) % keys.length + keys.length) % keys.length];
}
