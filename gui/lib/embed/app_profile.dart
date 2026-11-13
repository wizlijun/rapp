import '../ui/workspace_store.dart' show oneLine;
import 'session_port.dart';
import 'stream_choice.dart';

/// The file format version `apps.json` and the built-in asset carry.
const profilesVersion = 1;
const profileModes = {'duogray', 'duocolor', 'color16'};
const profileDensities = {'saver1x', 'adaptive', 'original'};
const profileFps = {1, 5, 15, 30};

/// What to do after the text of a message is sent into the app.
enum AfterSend { none, pressReturn }

/// JSON names are `none` / `return`; anything else is null (the field is dropped).
AfterSend? afterSendFromJson(Object? v) => switch (v) {
      'none' => AfterSend.none,
      'return' => AfterSend.pressReturn,
      _ => null,
    };

String afterSendToJson(AfterSend a) => a == AfterSend.none ? 'none' : 'return';

enum RuleAction { hide, noComposer }

/// One window rule: matches a window by kind and title glob; the first matching rule wins.
class WindowRule {
  const WindowRule({this.kind, this.title, this.child = true, required this.action});

  final WindowKind? kind;
  final String? title;

  /// True: only windows that are not the main window match.
  final bool child;
  final RuleAction action;

  Map<String, Object?> toJson() => {
        if (kind != null) 'kind': kind!.name,
        if (title != null) 'title': title,
        if (!child) 'child': false,
        'action': action.name,
      };

  /// A bad rule (not an object, unknown kind/action, wrong types) is null.
  static WindowRule? fromJson(Object? j) {
    if (j is! Map) return null;
    final k = j['kind'], t = j['title'], c = j['child'], a = j['action'];
    WindowKind? kind;
    if (k != null) {
      if (k is! String) return null;
      kind = WindowKind.values.where((v) => v.name == k).firstOrNull;
      if (kind == null) return null;
    }
    if (t != null && t is! String) return null;
    if (c != null && c is! bool) return null;
    final action = RuleAction.values.where((v) => v.name == a).firstOrNull;
    if (action == null) return null;
    return WindowRule(kind: kind, title: t as String?, child: (c as bool?) ?? true, action: action);
  }

  @override
  bool operator ==(Object other) =>
      other is WindowRule &&
      other.kind == kind &&
      other.title == title &&
      other.child == child &&
      other.action == action;

  @override
  int get hashCode => Object.hash(kind, title, child, action);

  @override
  String toString() => 'WindowRule($kind, $title, child: $child, $action)';
}

/// One profile as written in a file. Every field is nullable: null means "not written".
class AppProfile {
  AppProfile({
    required this.ids,
    this.name,
    this.mode,
    this.density,
    this.fps,
    this.afterSend,
    this.composer,
    this.windows,
    this.tested,
  });

  List<String> ids;
  String? name;
  String? mode;
  String? density;
  int? fps;
  AfterSend? afterSend;
  bool? composer;
  List<WindowRule>? windows;
  bool? tested;

  bool matches(String appId) {
    final a = appId.toLowerCase();
    return ids.any((i) => i.toLowerCase() == a);
  }

  bool sharesId(AppProfile other) => ids.any(other.matches);

  AppProfile copy() => AppProfile(
        ids: [...ids],
        name: name,
        mode: mode,
        density: density,
        fps: fps,
        afterSend: afterSend,
        composer: composer,
        windows: windows == null ? null : [...windows!],
        tested: tested,
      );

  Map<String, Object?> toJson() => {
        if (name != null) 'name': name,
        'ids': ids,
        if (mode != null || density != null || fps != null)
          'stream': {
            if (mode != null) 'mode': mode,
            if (density != null) 'density': density,
            if (fps != null) 'fps': fps,
          },
        if (afterSend != null) 'afterSend': afterSendToJson(afterSend!),
        if (composer != null) 'composer': composer,
        if (windows != null) 'windows': [for (final w in windows!) w.toJson()],
        if (tested != null) 'tested': tested,
      };

  /// Null when [j] is not an object or has no usable id. A bad field is dropped on its own (R7).
  static AppProfile? fromJson(Object? j) {
    if (j is! Map) return null;
    final rawIds = j['ids'];
    if (rawIds is! List) return null;
    final ids = [
      for (final i in rawIds)
        if (i is String && i.trim().isNotEmpty) i.trim(),
    ];
    if (ids.isEmpty) return null;

    String? name;
    final n = j['name'];
    if (n is String) {
      final one = oneLine(n);
      if (one.isNotEmpty) name = String.fromCharCodes(one.runes.take(40));
    }

    String? mode, density;
    int? fps;
    final s = j['stream'];
    if (s is Map) {
      if (profileModes.contains(s['mode'])) mode = s['mode'] as String;
      if (profileDensities.contains(s['density'])) density = s['density'] as String;
      if (s['fps'] is int && profileFps.contains(s['fps'])) fps = s['fps'] as int;
    }

    List<WindowRule>? windows;
    final w = j['windows'];
    if (w is List) {
      windows = [
        for (final r in w)
          ?WindowRule.fromJson(r),
      ];
    }

    return AppProfile(
      ids: ids,
      name: name,
      mode: mode,
      density: density,
      fps: fps,
      afterSend: afterSendFromJson(j['afterSend']),
      composer: j['composer'] is bool ? j['composer'] as bool : null,
      windows: windows,
      tested: j['tested'] is bool ? j['tested'] as bool : null,
    );
  }
}

/// Parses a whole file. A bad top level throws [FormatException]; bad entries are skipped (R7).
List<AppProfile> parseProfiles(Object? json) {
  if (json is! Map || json['version'] != profilesVersion || json['apps'] is! List) {
    throw const FormatException('bad app profiles file');
  }
  return [
    for (final e in json['apps'] as List)
      ?AppProfile.fromJson(e),
  ];
}

Map<String, Object?> profilesToJson(List<AppProfile> apps) => {
      'version': profilesVersion,
      'apps': [for (final a in apps) a.toJson()],
    };

/// A profile with every field filled in. `name == null` means no profile matched the app.
class ResolvedProfile {
  const ResolvedProfile({
    this.name,
    this.stream = startChoice,
    this.afterSend = AfterSend.none,
    this.composer = true,
    this.windows = const [],
    this.tested = true,
  });

  static const generic = ResolvedProfile();

  final String? name;
  final StreamChoice stream;
  final AfterSend afterSend;
  final bool composer;
  final List<WindowRule> windows;
  final bool tested;
}

/// `*` matches any run (also empty); everything else is literal, case-insensitive,
/// compared per UTF-16 code unit.
bool globMatch(String pattern, String text) {
  final p = pattern.toLowerCase(), t = text.toLowerCase();
  var i = 0, j = 0, star = -1, mark = 0;
  while (j < t.length) {
    if (i < p.length && p[i] == '*') {
      star = i++;
      mark = j;
    } else if (i < p.length && p[i] == t[j]) {
      i++;
      j++;
    } else if (star >= 0) {
      i = star + 1;
      j = ++mark;
    } else {
      return false;
    }
  }
  while (i < p.length && p[i] == '*') {
    i++;
  }
  return i == p.length;
}

/// Mine over built-in, field by field, then the generic default (R6).
ResolvedProfile resolveProfile(String appId, {required List<AppProfile> mine, required List<AppProfile> builtin}) {
  AppProfile? first(List<AppProfile> l) => l.where((p) => p.matches(appId)).firstOrNull;
  final m = first(mine), b = first(builtin);
  if (m == null && b == null) return ResolvedProfile.generic;
  T? pick<T>(T? Function(AppProfile) f) => (m == null ? null : f(m)) ?? (b == null ? null : f(b));
  return ResolvedProfile(
    name: pick((p) => p.name) ?? (m ?? b)!.ids.first,
    stream: StreamChoice(pick((p) => p.mode) ?? startChoice.mode, pick((p) => p.density) ?? startChoice.density,
        pick((p) => p.fps) ?? startChoice.fps),
    afterSend: pick((p) => p.afterSend) ?? AfterSend.none,
    composer: pick((p) => p.composer) ?? true,
    windows: pick((p) => p.windows) ?? const [],
    tested: pick((p) => p.tested) ?? true,
  );
}
