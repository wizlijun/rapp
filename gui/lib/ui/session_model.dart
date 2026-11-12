// Session list model: entries, grouping, prev/next stepping.
import 'lamp.dart';

const pathLabels = {'lan': '局域网', 'direct': '直连', 'relay': '中继'};

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
  });

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
String openVerb(Lamp? lamp) => switch (lamp) {
      null || Lamp.notOpened => '打开',
      Lamp.disconnected => '重连',
      _ => '切到',
    };

enum Grouping { device, app }

String groupingLabel(Grouping g) => switch (g) {
      Grouping.device => '按设备',
      Grouping.app => '按 App',
    };

class SessionGroup {
  const SessionGroup(this.title, this.entries);
  final String title;
  final List<SessionEntry> entries;
}

List<SessionGroup> groupSessions(List<SessionEntry> all, Grouping g) {
  String titleOf(SessionEntry e) => g == Grouping.device ? e.device : e.appName;
  // Stable sort via original-index tiebreak.
  final indexed = [for (var i = 0; i < all.length; i++) (i, all[i])];
  indexed.sort((a, b) {
    var c = a.$2.device.compareTo(b.$2.device);
    if (c == 0) c = a.$2.appName.compareTo(b.$2.appName);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final byTitle = <String, List<SessionEntry>>{};
  for (final (_, e) in indexed) {
    byTitle.putIfAbsent(titleOf(e), () => []).add(e);
  }
  final titles = byTitle.keys.toList()..sort();
  return [for (final t in titles) SessionGroup(t, byTitle[t]!)];
}

String? stepKey(List<SessionGroup> groups, String? current, int delta) {
  final keys = [for (final g in groups) for (final e in g.entries) e.key];
  if (keys.isEmpty) return null;
  final i = current == null ? -1 : keys.indexOf(current);
  if (i < 0) return keys.first;
  return keys[((i + delta) % keys.length + keys.length) % keys.length];
}
