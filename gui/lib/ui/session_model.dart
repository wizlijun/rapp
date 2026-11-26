// Session list model: entries, grouping, prev/next stepping.
import '../hub_client.dart' show TermPs;
import '../labels.dart';
import '../term/term_id.dart';
import 'lamp.dart';
import 'projects.dart';
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
    this.ps,
    this.inferred = false,
    this.fg,
    this.label,
    this.standby,
    this.openOn,
  });

  /// Where other apps have it open, `在 <设备名> 上开着`: a 别处开着 card; null for every other card.
  final String? openOn;

  /// The title and note the user gave this session on its device; null: none (or the device predates labels).
  final SessionLabel? label;

  /// Not open in this window: a card that stands for a labelled session (see [Standby]); null for an open one.
  final Standby? standby;

  /// A text terminal's program in front (claude, codex, zsh), from its live row; null when not known.
  final String? fg;

  /// The line under the title starts with [termKindWord]: a text terminal whose title names its program instead.
  bool get kindNoted => isTermApp(app) && fg != null && fg!.isNotEmpty;

  /// [line] under the title, with [termKindWord] in front when [kindNoted].
  String noted(String line) => !kindNoted ? line : (line.isEmpty ? termKindWord : '$termKindWord · $line');

  /// A text terminal's program status, from its live row; null when it reports none, is gone, or its device is offline.
  final TermPs? ps;

  /// [ps] was read off an app's screen by state rules, not reported by a program.
  final bool inferred;

  /// Disconnected because another device took it over: the button says 「拿回来」.
  final bool takenOver;

  /// null while the open request is still in flight (lamp = connecting).
  final Object? sid;
  final String id;
  final String app;
  /// The app's name; for a text terminal its current name on the device (not the label, see [title]).
  final String appName;
  final String device;
  final String path;
  final Lamp lamp;

  /// Bytes received in the last second; only on a live embedded session.
  final int? bytesPerSecond;

  /// Why it disconnected, in words; only on a disconnected embedded session.
  final String? reason;

  String get key => '$id/$app';

  /// What the session is called when it has no label: `<program> · <name>` for a text terminal ([termTitle]).
  String get defaultTitle => isTermApp(app) ? termTitle(appName, fg: fg) : appName;

  /// What the session is called wherever it is listed: its label's title, else [defaultTitle].
  String get title => label?.title.isNotEmpty == true ? label!.title : defaultTitle;

  /// The label's note; empty when there is none.
  String get note => label?.note ?? '';
}

/// Why a labelled session's card is there without being open in this window.
enum Standby {
  /// Running on its device, not open here: 「打开」.
  open,

  /// A text terminal that is gone: 「启动」 opens a new one that takes its label.
  stopped,
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
  const SessionGroup(this.title, this.entries, {this.projectId});
  final String title;

  /// The project this group is, in project mode; null for 未归项目的 and device/app groups.
  final String? projectId;
  final List<SessionEntry> entries;
}

const otherGroupTitle = '未归项目的';

/// [groups] with each group's standing cards ([SessionEntry.standby]) moved to its end, in their order.
List<SessionGroup> standLast(List<SessionGroup> groups) => [
      for (final g in groups)
        SessionGroup(g.title, [...g.entries.where((e) => e.standby == null), ...g.entries.where((e) => e.standby != null)],
            projectId: g.projectId),
    ];

/// [all] sorted by device, then app name; stable.
List<SessionEntry> _byDeviceThenApp(List<SessionEntry> all) {
  // Stable sort via original-index tiebreak.
  final indexed = [for (var i = 0; i < all.length; i++) (i, all[i])];
  indexed.sort((a, b) {
    var c = a.$2.device.compareTo(b.$2.device);
    if (c == 0) c = a.$2.title.compareTo(b.$2.title);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final (_, e) in indexed) e];
}

/// By project, a session in several projects appears in each (K15). Project groups follow
/// [orderedProjects]; the project [first] names (if it has open members) goes before them all.
List<SessionGroup> groupSessions(List<SessionEntry> all, Grouping g,
    {List<Project> projects = const [], String? first}) {
  if (g == Grouping.project) {
    final byKey = {for (final e in all) e.key: e};
    final inProject = <String>{};
    final groups = <SessionGroup>[];
    final ordered = orderedProjects(projects);
    final at = ordered.indexWhere((p) => p.id == first);
    if (at > 0) ordered.insert(0, ordered.removeAt(at));
    for (final p in ordered) {
      final es = [for (final m in p.members) ?byKey[m.key]];
      if (es.isEmpty) continue;
      inProject.addAll(es.map((e) => e.key));
      groups.add(SessionGroup(p.name, es, projectId: p.id));
    }
    final rest = _byDeviceThenApp([for (final e in all) if (!inProject.contains(e.key)) e]);
    if (rest.isNotEmpty) groups.add(SessionGroup(otherGroupTitle, rest));
    return groups;
  }
  // By app: what it is, not what the user called it (a label does not move a session to a group of its own).
  String titleOf(SessionEntry e) => g == Grouping.device ? e.device : e.defaultTitle;
  final byTitle = <String, List<SessionEntry>>{};
  for (final e in _byDeviceThenApp(all)) {
    byTitle.putIfAbsent(titleOf(e), () => []).add(e);
  }
  final titles = byTitle.keys.toList()..sort();
  return [for (final t in titles) SessionGroup(t, byTitle[t]!)];
}

/// The next (or previous) key in list order. With [within], only those keys that are listed (open)
/// take part; a [current] outside them starts from the first (delta > 0) or last (delta < 0).
String? stepKey(List<SessionGroup> groups, String? current, int delta, {List<String>? within}) {
  var keys = {for (final g in groups) for (final e in g.entries) e.key}.toList();
  if (within != null) keys = [for (final k in within) if (keys.contains(k)) k];
  if (keys.isEmpty) return null;
  final i = current == null ? -1 : keys.indexOf(current);
  if (i < 0) return within != null && delta < 0 ? keys.last : keys.first;
  return keys[((i + delta) % keys.length + keys.length) % keys.length];
}

/// A's whole-desktop entry (`desktop:`, the main screen) or one of its other screens (`desktop:<id>`).
bool isDesktopApp(String app) => app.startsWith('desktop:');

/// One of A's other screens (`desktop:<id>`): opened alongside `desktop:`, never listed on its own.
bool isDesktopScreen(String app) => app.length > 8 && app.startsWith('desktop:');
