// The four 快捷区 docs of this device — 常用语和命令, 键盘布局, 星标, 次数 — in `<dir>/quick.json`, each `{at, data}`
// with `at` in ms (quick-row spec §10.1). Built from gui.json's `phrases` the first time; the sync reads [docOf] and
// writes through [adopt] and [floor]. The 按键动作 doc of 0.15.63/64 is read once and dropped (cmd-menu design).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../embed/phrases.dart';
import '../embed/strip_cmds.dart';
import 'key_layout.dart';
import 'quick_usage.dart';

/// One doc as stored and synced: when it was last changed (ms) and its JSON.
@immutable
class QuickDoc {
  const QuickDoc(this.at, this.data);
  final int at;
  final Object? data;
}

/// The docs every device shares; `usage` is per device and goes apart.
const quickDocNames = ['phrases', 'layout', 'stars'];

const _allNames = [...quickDocNames, 'usage'];

/// A random 8-character id of `[a-z0-9]`.
String quickId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return String.fromCharCodes([for (var i = 0; i < 8; i++) chars.codeUnitAt(r.nextInt(chars.length))]);
}

/// gui.json's list as the 常用语 doc (spec §10.1): as it is, ids added, and 切模式 once (it used to be a key on the
/// keyboard row; the old list never had it), after 新对话.
List<StripItem> _migrateList(List<StripItem> legacy) {
  final phrases = List.of(legacy);
  if (!phrases.any((it) => it is StripCmd && it.id == 'mode')) {
    final at = phrases.indexWhere((it) => it is StripCmd && it.id == 'new');
    phrases.insert(at < 0 ? 0 : at + 1, const StripCmd('mode'));
  }
  return _withIds(phrases);
}

/// The 常用语 doc of a fresh install, and what 恢复默认 brings back: gui.json's default list as migrated, so every
/// built-in command, 搜历史 too, then the default phrases. One definition for both.
List<StripItem> get defaultQuickPhrases => _migrateList(defaultStripItems);

/// The ref the old 搜历史 按键动作 had; it is the command `p:search` now. Any other `k:` ref is of an action that is gone.
const _oldSearch = 'k:search';

/// [stars] as this version reads them: `k:search` is `p:search`, other `k:` refs go.
List<String> _starsNow(List<String> stars) =>
    _dedupe([for (final s in stars) if (s == _oldSearch) 'p:search' else if (!s.startsWith('k:')) s]);

/// [u] as this version reads it: the counts of `k:search` added to `p:search`'s, other `k:` refs dropped.
Usage _usageNow(Usage u) {
  if (!u.keys.any((r) => r.startsWith('k:'))) return u;
  final out = <String, Map<String, int>>{
    for (final e in u.entries)
      if (!e.key.startsWith('k:')) e.key: Map.of(e.value),
  };
  final old = u[_oldSearch];
  if (old != null) {
    final days = out.putIfAbsent('p:search', () => <String, int>{});
    old.forEach((d, n) => days[d] = (days[d] ?? 0) + n);
  }
  return out;
}

/// [phrases] with 搜历史 back as a command, after the last command, when it is not there (a quick.json of 0.15.63/64
/// moved it to its 按键动作); the name the action was given goes with it. Null: nothing to add.
List<StripItem>? _withSearch(List<StripItem> phrases, Object? keys) {
  if (phrases.any((it) => it is StripCmd && it.id == 'search')) return null;
  String? label;
  if (keys is List) {
    for (final e in keys) {
      if (e is Map && e['id'] == 'search' && e['label'] is String) {
        final l = (e['label'] as String).trim();
        if (l.isNotEmpty && l != builtinCmds['search']!.label) label = l;
        break;
      }
    }
  }
  final at = phrases.lastIndexWhere((it) => it is StripCmd) + 1;
  return List.of(phrases)..insert(at, StripCmd('search', label: label));
}

/// [l] with an id on every phrase that has none (Ruling 10): a default phrase's text takes its fixed id while no
/// other phrase of the list holds it, anything else a fresh one.
List<StripItem> _withIds(List<StripItem> l) {
  final used = {for (final it in l) if (it is Phrase && it.id != null) it.id!};
  String idFor(String text) {
    final fixed = _defaultIds[text];
    final id = fixed != null && !used.contains(fixed) ? fixed : quickId();
    used.add(id);
    return id;
  }

  return [for (final it in l) it is Phrase && it.id == null ? it.withId(idFor(it.text)) : it];
}

/// The default phrases' ids, the same on every device and every time (so 恢复默认 keeps their stars and counts): `d`
/// and the text's 32-bit FNV-1a in base 36.
final Map<String, String> _defaultIds = {for (final p in defaultPhrases) p.text: _fixedId(p.text)};

String _fixedId(String text) {
  var h = 0x811c9dc5;
  for (final c in text.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return 'd${h.toRadixString(36).padLeft(7, '0')}';
}

bool _needsIds(List<StripItem> l) => l.any((it) => it is Phrase && it.id == null);

List<StripItem>? _phrasesFrom(Object? j) => j is List ? [for (final e in j) ?stripItemFromJson(e)] : null;

KeyLayout? _layoutFrom(Object? j) => j is Map && j['rows'] is List ? KeyLayout.fromJson(j) : null;

List<String>? _starsFrom(Object? j) => j is List ? _dedupe([for (final e in j) if (e is String) e]) : null;

Usage? _usageFrom(Object? j) => j is Map ? usageFromJson(j) : null;

List<String> _dedupe(Iterable<String> l) {
  final seen = <String>{};
  return [for (final s in l) if (seen.add(s)) s];
}

class QuickPrefs extends ChangeNotifier {
  QuickPrefs._(this._dir, this._clock, this._legacy, this._phrases, this._layout, this._stars, this._usage, Map<String, int> at)
      : _at = at;

  /// From `<dir>/quick.json`, or built from [legacy] (gui.json's `phrases`) when there is none. [dir] null (no device
  /// id yet): nothing is read or written. An unreadable file is moved to `quick.json.bad` and rebuilt; a bad doc alone
  /// goes back to its default with `at` 0 (Ruling 11); one that cannot be moved aside, or one written by a newer
  /// version (`v` above 1), is used as far as it reads but never written over. Never throws.
  static QuickPrefs load(String? dir, {required List<StripItem> legacy, DateTime Function() clock = DateTime.now}) {
    if (dir == null) return QuickPrefs.migrate(legacy, clock: clock);
    final f = File('$dir/quick.json');
    if (!f.existsSync()) return QuickPrefs.migrate(legacy, dir: dir, clock: clock);
    Map? j;
    try {
      final v = jsonDecode(f.readAsStringSync());
      if (v is Map) j = v;
    } catch (_) {}
    if (j == null) {
      try {
        f.renameSync('$dir/quick.json.bad');
      } catch (_) {
        // The user's only copy: kept as it is, and this run's settings live in memory.
        return QuickPrefs.migrate(legacy, dir: dir, clock: clock, keep: '快捷区设置文件读不了，也挪不开，原样留着');
      }
      return QuickPrefs.migrate(legacy, dir: dir, clock: clock);
    }
    final ver = j['v'];
    final keep = ver is int && ver > 1 ? '快捷区设置文件是更新的版本写的，原样留着' : null;
    final at = <String, int>{};
    var repaired = false;
    T doc<T>(String name, T? Function(Object?) parse, T Function() fallback) {
      final d = j![name];
      final a = d is Map ? d['at'] : null;
      T? v;
      try {
        v = d is Map && a is int && a >= 0 ? parse(d['data']) : null;
      } catch (_) {}
      if (v == null) {
        repaired = true;
        at[name] = 0;
        return fallback();
      }
      at[name] = a as int;
      return v;
    }

    var phrases = doc('phrases', _phrasesFrom, () => _migrateList(legacy));
    if (_needsIds(phrases)) {
      phrases = _withIds(phrases);
      repaired = true;
    }
    var stars = doc('stars', _starsFrom, () => <String>[]);
    var usage = doc('usage', _usageFrom, () => <String, Map<String, int>>{});
    if (j.containsKey('keys')) {
      // Written by 0.15.63/64: 搜历史 back among the commands, its star and counts with it; the docs that changed move
      // on so the sync sends them. The keys doc is not written again, so this happens once.
      final now = clock().millisecondsSinceEpoch;
      void moved(String name) => at[name] = max(now, at[name]! + 1);
      final back = _withSearch(phrases, (j['keys'] is Map ? j['keys'] as Map : const {})['data']);
      if (back != null) {
        phrases = back;
        moved('phrases');
      }
      final s2 = _starsNow(stars);
      if (!listEquals(s2, stars)) {
        stars = s2;
        moved('stars');
      }
      final u2 = _usageNow(usage);
      if (!identical(u2, usage)) {
        usage = u2;
        moved('usage');
      }
      repaired = true;
    }
    final q = QuickPrefs._(
      dir,
      clock,
      legacy,
      phrases,
      doc('layout', _layoutFrom, () => KeyLayout.fallback),
      stars,
      usage,
      at,
    ).._keep = keep;
    if (repaired) q._save();
    return q;
  }

  /// The docs as gui.json's list gives them, every `at` 0 (spec §10.1); written at once when [dir] is set, so the
  /// new phrase ids stay.
  /// [keep]: the file in [dir] is not to be written over; why, in words (see [load]).
  factory QuickPrefs.migrate(List<StripItem> legacy,
      {String? dir, DateTime Function() clock = DateTime.now, String? keep}) {
    final q = QuickPrefs._(dir, clock, legacy, _migrateList(legacy), KeyLayout.fallback, [], {},
        {for (final n in _allNames) n: 0})
      .._keep = keep;
    q._save();
    return q;
  }

  final String? _dir;
  final DateTime Function() _clock;
  final List<StripItem> _legacy;
  List<StripItem> _phrases;
  KeyLayout _layout; // as stored; [layout] is it cleaned
  KeyLayout? _cleaned;
  List<String> _stars;
  Usage _usage;
  Map<String, Usage> _others = const {};
  final Map<String, int> _at;

  /// Per doc, the lowest `at` a local change may take: the service's `at` + 1 (spec §10.3), set by the sync (from
  /// quick-sync.json's `synced` at its start, then from each copy it hears of).
  final Map<String, int> floor = {};

  /// Told the doc's name after each local change (not after [adopt]): the sync sends it.
  void Function(String name)? onLocal;

  /// Where later writes go, when set: MainState points it at its data dir's device folder, so a device id that turns
  /// up after the start, or a moved data root, is followed as gui.json is. Null result: nothing is written (R22).
  String? Function()? dirOf;

  /// Told when quick.json could not be written.
  void Function(Object error)? onSaveError;

  /// The last write's error, null once one works: a write at the start fails before anyone sets [onSaveError].
  Object? lastSaveError;

  /// Set when quick.json must stay as it was found (see [load]): every write is refused with this reason.
  String? _keep;

  /// 常用语和命令, in list order (命令▾ and 常用语▾ each show their own kind).
  List<StripItem> get phrases => _phrases;

  /// The key bar's layout, cleaned.
  KeyLayout get layout => _cleaned ??= _layout.cleaned();

  /// Refs (`p:`) in the order they were starred.
  List<String> get stars => _stars;

  /// This device's own counts.
  Usage get usage => _usage;

  /// The other devices' counts, by device id (filled by the sync).
  Map<String, Usage> get others => _others;

  int atOf(String name) => _at[name] ?? 0;

  QuickDoc docOf(String name) => QuickDoc(atOf(name), switch (name) {
        'phrases' => [for (final p in _phrases) p.toJson()],
        'layout' => _layout.toJson(),
        'stars' => List<String>.of(_stars),
        'usage' => {for (final e in _usage.entries) e.key: Map<String, int>.of(e.value)},
        _ => throw ArgumentError.value(name, 'name'),
      });

  // ---- local changes ----

  /// The whole 常用语 list replaced; a phrase without an id gets one, stars of items gone are dropped.
  void setPhrases(List<StripItem> v) {
    _phrases = _withIds(v);
    final have = {for (final it in _phrases) refOf(it)};
    _commit(['phrases', if (_dropStars('p:', have)) 'stars']);
  }

  void setLayout(KeyLayout l) {
    _layout = l;
    _commit(['layout']);
  }

  void setStars(List<String> v) {
    _stars = _dedupe(v);
    _commit(['stars']);
  }

  /// Starred at the end, or unstarred.
  void toggleStar(String ref) {
    _stars = _stars.contains(ref) ? [for (final s in _stars) if (s != ref) s] : [..._stars, ref];
    _commit(['stars']);
  }

  /// [ref] first among the stars (starred if it was not).
  void starFirst(String ref) {
    _stars = [ref, for (final s in _stars) if (s != ref) s];
    _commit(['stars']);
  }

  /// One more use of [ref] today; days past 30 are dropped.
  void recordUse(String ref) {
    _usage = recordUsage(_usage, ref, _clock());
    _commit(['usage']);
  }

  // ---- sync ----

  /// [d] takes the place of doc [name], `at` and all; bad data reads as the default. No [onLocal].
  void adopt(String name, QuickDoc d) {
    T? read<T>(T? Function(Object?) parse) {
      try {
        return parse(d.data);
      } catch (_) {
        return null;
      }
    }

    switch (name) {
      case 'phrases':
        final p = read(_phrasesFrom);
        _phrases = p == null ? _migrateList(_legacy) : _withIds(p);
      case 'layout':
        _layout = read(_layoutFrom) ?? KeyLayout.fallback;
      case 'stars':
        _stars = _starsNow(read(_starsFrom) ?? []);
      case 'usage':
        _usage = read(_usageFrom) ?? {};
      default:
        return;
    }
    _at[name] = d.at;
    _cleaned = null;
    _save();
    notifyListeners();
  }

  /// A device still on 0.15.63/64 counts 搜历史 as `k:search`: read as the command's.
  void setOthers(Map<String, Usage> v) {
    _others = {for (final e in v.entries) e.key: _usageNow(e.value)};
    notifyListeners();
  }

  // ---- inner ----

  /// Drops the stars starting with [prefix] that are not in [have]; true when any went.
  bool _dropStars(String prefix, Set<String> have) {
    final kept = [for (final s in _stars) if (!s.startsWith(prefix) || have.contains(s)) s];
    if (kept.length == _stars.length) return false;
    _stars = kept;
    return true;
  }

  void _commit(List<String> names) {
    final now = _clock().millisecondsSinceEpoch;
    for (final n in names) {
      // Above the doc's own `at` too: a clock behind the one that wrote it (or one that went back) still moves it on.
      _at[n] = max(max(now, floor[n] ?? 0), (_at[n] ?? 0) + 1);
    }
    _cleaned = null;
    _save();
    notifyListeners();
    for (final n in names) {
      onLocal?.call(n);
    }
  }

  /// Written to a `.tmp` and renamed over; nothing without a dir (R22). Errors go to [onSaveError].
  void _save() {
    final dir = dirOf != null ? dirOf!() : _dir;
    if (dir == null) return;
    if (_keep != null) {
      lastSaveError = FileSystemException(_keep!, '$dir/quick.json');
      onSaveError?.call(lastSaveError!);
      return;
    }
    try {
      Directory(dir).createSync(recursive: true);
      final tmp = File('$dir/quick.json.tmp');
      tmp.writeAsStringSync(jsonEncode({
        'v': 1,
        for (final n in _allNames)
          n: {
            'at': atOf(n),
            'data': docOf(n).data,
          },
      }));
      tmp.renameSync('$dir/quick.json');
      lastSaveError = null;
    } catch (e) {
      lastSaveError = e;
      onSaveError?.call(e);
    }
  }
}
