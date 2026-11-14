// apps.json: my app profiles, kept in the data root's shared/ dir, plus the built-in ones.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../embed/app_profile.dart';
import '../embed/session_port.dart';
import '../embed/stream_choice.dart';
import '../embed/window_rules.dart';

const appsFile = 'apps.json';
const appsLoadProblem = 'app 配置没有读到，已从空白开始';
const appsSaveProblem = 'app 配置没有存上';

enum ProfileSource { builtin, mine, changed }

String sourceLabel(ProfileSource s) => switch (s) {
      ProfileSource.builtin => '内置',
      ProfileSource.mine => '我的',
      ProfileSource.changed => '内置 + 我改过',
    };

class ProfileRow {
  const ProfileRow({
    required this.name,
    required this.ids,
    required this.source,
    required this.tested,
    this.duplicateOf,
    this.mine,
    this.builtin,
  });
  final String name;
  final List<String> ids;
  final ProfileSource source;
  final bool tested;

  /// Display name of an earlier profile of mine that shares an id with this one.
  final String? duplicateOf;
  final AppProfile? mine, builtin;
}

class AppProfileStore extends ChangeNotifier {
  AppProfileStore(this.dir, {this.builtin = const [], List<AppProfile>? mine, this.problem})
      : _mine = mine ?? [];

  final String dir;
  final List<AppProfile> builtin;
  final List<AppProfile> _mine;
  String? problem;

  List<AppProfile> get mine => _mine;

  /// Never throws. No or bad [builtinJson] means no built-ins (not a problem). A missing
  /// apps.json is empty; an unreadable one moves to apps.json.bad and sets [appsLoadProblem].
  static AppProfileStore load(String dir, String? builtinJson) {
    var builtin = <AppProfile>[];
    if (builtinJson != null) {
      try {
        builtin = parseProfiles(jsonDecode(builtinJson));
      } catch (_) {}
    }
    return loadWith(dir, builtin);
  }

  /// [load] with the built-ins already parsed (a relocated data root rereads only apps.json).
  static AppProfileStore loadWith(String dir, List<AppProfile> builtin) {
    final f = File('$dir/$appsFile');
    try {
      if (!f.existsSync()) return AppProfileStore(dir, builtin: builtin);
    } catch (_) {
      return AppProfileStore(dir, builtin: builtin, problem: appsLoadProblem);
    }
    try {
      return AppProfileStore(dir, builtin: builtin, mine: parseProfiles(jsonDecode(f.readAsStringSync())));
    } catch (_) {
      try {
        f.renameSync('$dir/$appsFile.bad');
      } catch (_) {}
      return AppProfileStore(dir, builtin: builtin, problem: appsLoadProblem);
    }
  }

  ResolvedProfile resolve(String appId) => resolveProfile(appId, mine: _mine, builtin: builtin);
  AppProfile? builtinFor(String appId) => builtin.where((p) => p.matches(appId)).firstOrNull;
  AppProfile? mineFor(String appId) => _mine.where((p) => p.matches(appId)).firstOrNull;

  List<AppProfile> snapshot() => [for (final p in _mine) p.copy()];

  void restore(List<AppProfile> snap) {
    _mine
      ..clear()
      ..addAll(snap.map((p) => p.copy()));
    _commit();
  }

  void put(AppProfile p, {AppProfile? replacing}) {
    final i = replacing == null ? -1 : _mine.indexOf(replacing);
    if (i >= 0) {
      _mine[i] = p;
    } else {
      _mine.add(p);
    }
    _commit();
  }

  void remove(AppProfile p) {
    _mine.remove(p);
    _commit();
  }

  void restoreBuiltin(AppProfile b) {
    _mine.removeWhere((p) => p.sharesId(b));
    _commit();
  }

  /// My profile for [appId], created (and appended) when there is none (R16).
  AppProfile _target(String appId, String appName) {
    final existing = mineFor(appId);
    if (existing != null) return existing;
    final b = builtinFor(appId);
    final p = AppProfile(ids: b == null ? [appId] : [...b.ids], name: b == null ? appName : null);
    _mine.add(p);
    return p;
  }

  void addRule(String appId, String appName, WindowRule r) {
    final p = _target(appId, appName);
    p.windows ??= [...(builtinFor(appId)?.windows ?? const <WindowRule>[])];
    p.windows!.insert(0, r);
    _commit();
  }

  bool removeHideRule(String appId, RemoteWindow w, {required bool isMain}) {
    final rules = resolve(appId).windows;
    final i = rules.indexWhere((r) => r.action == RuleAction.hide && ruleMatches(r, w, isMain: isMain));
    if (i < 0) return false;
    final p = _target(appId, resolve(appId).name ?? appId);
    p.windows = [...rules]..removeAt(i);
    _commit();
    return true;
  }

  void rememberStream(String appId, String appName, StreamChoice c) {
    final p = _target(appId, appName);
    p.mode = c.mode;
    p.density = c.density;
    p.fps = c.fps;
    _commit();
  }

  /// Marks the app's text box ([p]), or clears the mark (null).
  void setInputPoint(String appId, String appName, InputPoint? p) {
    _target(appId, appName).input = p;
    _commit();
  }

  List<ProfileRow> rows() {
    final out = <ProfileRow>[];
    for (final b in builtin) {
      final m = _mine.where((p) => p.sharesId(b)).firstOrNull;
      final r = resolve(b.ids.first);
      out.add(ProfileRow(
        name: r.name ?? b.ids.first,
        ids: b.ids,
        source: m == null ? ProfileSource.builtin : ProfileSource.changed,
        tested: r.tested,
        mine: m,
        builtin: b,
      ));
    }
    final listed = <AppProfile>[];
    for (final p in _mine) {
      if (builtin.any(p.sharesId)) continue;
      final earlier = listed.where(p.sharesId).firstOrNull;
      out.add(ProfileRow(
        name: p.name ?? p.ids.first,
        ids: p.ids,
        source: ProfileSource.mine,
        tested: p.tested ?? true,
        duplicateOf: earlier == null ? null : (earlier.name ?? earlier.ids.first),
        mine: p,
      ));
      listed.add(p);
    }
    return out;
  }

  void _commit() {
    try {
      _save();
      if (problem == appsSaveProblem) problem = null;
    } catch (_) {
      problem = appsSaveProblem;
    }
    notifyListeners();
  }

  /// Writes through a temp file and a rename so a failed write leaves the old file whole.
  void _save() {
    Directory(dir).createSync(recursive: true);
    final tmp = File('$dir/$appsFile.tmp');
    try {
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(profilesToJson(_mine)), flush: true);
      tmp.renameSync('$dir/$appsFile');
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }
}
