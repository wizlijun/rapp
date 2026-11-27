// The five 快捷区 docs of this device — 常用语和命令, 按键动作, 键盘布局, 星标, 次数 — in `<dir>/quick.json`, each
// `{at, data}` with `at` in ms (quick-row spec §10.1). Built from gui.json's `phrases` the first time; the sync
// (later tasks) reads [docOf] and writes through [adopt] and [floor].
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../embed/key_bar_keys.dart';
import '../embed/phrases.dart';
import '../embed/strip_cmds.dart';
import 'key_actions.dart';
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
const quickDocNames = ['phrases', 'keys', 'layout', 'stars'];

const _allNames = [...quickDocNames, 'usage'];

const _wireKeys = {
  'Esc': 'esc',
  'Tab': 'tab',
  'Enter': 'enter',
  'Backspace': 'bksp',
  'Left': 'left',
  'Up': 'up',
  'Down': 'down',
  'Right': 'right',
  'PageUp': 'pgup',
  'PageDown': 'pgdn',
};

/// The chord a key-bar key sends, from its wire name (`Ctrl-O` → `ctrl+o`); null when it has none or a chord cannot
/// say it.
Chord? chordOfBarKey(String id) {
  final wire = barKeys[id]?.wire;
  if (wire == null) return null;
  final parts = wire.split('-');
  final base = parts.last;
  final mods = parts.sublist(0, parts.length - 1);
  if (mods.any((m) => !const {'Ctrl', 'Alt', 'Shift'}.contains(m))) return null;
  final key = RegExp(r'^[A-Za-z0-9]$').hasMatch(base) ? base.toLowerCase() : _wireKeys[base];
  if (key == null) return null;
  return Chord(key, ctrl: mods.contains('Ctrl'), alt: mods.contains('Alt'), shift: mods.contains('Shift'));
}

/// gui.json's list as the 常用语 doc and the 按键动作 doc (spec §10.1, Ruling P1). `StripCmd('search')` with a text
/// anywhere stays a command; otherwise it leaves the list and its keys (and name) go to the `search` action.
({List<StripItem> phrases, List<KeyAction> keys}) _migrateLists(List<StripItem> legacy) {
  final builtin = builtinKeyActions.firstWhere((a) => a.id == 'search');
  KeyAction? search;
  final phrases = <StripItem>[];
  for (final it in legacy) {
    if (it is StripCmd && it.id == 'search' && !it.per.values.any((a) => a is CmdText)) {
      search ??= KeyAction('search', label: it.label ?? builtin.label, chord: builtin.chord, per: {
        ...builtin.per,
        for (final e in it.per.entries) e.key: e.value is CmdKey ? chordOfBarKey((e.value as CmdKey).key) : null,
      });
      continue;
    }
    phrases.add(it);
  }
  return (
    phrases: _withIds(phrases),
    keys: [for (final a in builtinKeyActions) a.id == 'search' && search != null ? search : a],
  );
}

/// [l] with a fresh id on every phrase that has none (Ruling 10).
List<StripItem> _withIds(List<StripItem> l) =>
    [for (final it in l) it is Phrase && it.id == null ? it.withId(quickId()) : it];

bool _needsIds(List<StripItem> l) => l.any((it) => it is Phrase && it.id == null);

List<StripItem>? _phrasesFrom(Object? j) => j is List ? [for (final e in j) ?stripItemFromJson(e)] : null;

/// Bad actions dropped; an id is kept once, first place wins.
List<KeyAction>? _keysFrom(Object? j) {
  if (j is! List) return null;
  final seen = <String>{};
  return [
    for (final e in j)
      if (KeyAction.fromJson(e) case final a? when seen.add(a.id)) a,
  ];
}

KeyLayout? _layoutFrom(Object? j) => j is Map && j['rows'] is List ? KeyLayout.fromJson(j) : null;

List<String>? _starsFrom(Object? j) => j is List ? _dedupe([for (final e in j) if (e is String) e]) : null;

Usage? _usageFrom(Object? j) => j is Map ? usageFromJson(j) : null;

List<String> _dedupe(Iterable<String> l) {
  final seen = <String>{};
  return [for (final s in l) if (seen.add(s)) s];
}

KeyLayout _without(KeyLayout l, Set<String> cells) =>
    KeyLayout([for (final r in l.rows) [for (final c in r) if (!cells.contains(c)) c]]);

class QuickPrefs extends ChangeNotifier {
  QuickPrefs._(this._dir, this._clock, this._legacy, this._phrases, this._keys, this._layout, this._stars, this._usage,
      Map<String, int> at)
      : _at = at;

  /// From `<dir>/quick.json`, or built from [legacy] (gui.json's `phrases`) when there is none. [dir] null (no device
  /// id yet): nothing is read or written. An unreadable file is moved to `quick.json.bad` and rebuilt; a bad doc alone
  /// goes back to its default with `at` 0 (Ruling 11). Never throws.
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
      } catch (_) {}
      return QuickPrefs.migrate(legacy, dir: dir, clock: clock);
    }
    final at = <String, int>{};
    var repaired = false;
    T doc<T>(String name, T? Function(Object?) parse, T Function() fallback) {
      final d = j![name];
      final a = d is Map ? d['at'] : null;
      final v = d is Map && a is int && a >= 0 ? parse(d['data']) : null;
      if (v == null) {
        repaired = true;
        at[name] = 0;
        return fallback();
      }
      at[name] = a as int;
      return v;
    }

    final m = _migrateLists(legacy);
    var phrases = doc('phrases', _phrasesFrom, () => m.phrases);
    if (_needsIds(phrases)) {
      phrases = _withIds(phrases);
      repaired = true;
    }
    final q = QuickPrefs._(
      dir,
      clock,
      legacy,
      phrases,
      doc('keys', _keysFrom, () => m.keys),
      doc('layout', _layoutFrom, () => KeyLayout.fallback),
      doc('stars', _starsFrom, () => <String>[]),
      doc('usage', _usageFrom, () => <String, Map<String, int>>{}),
      at,
    );
    if (repaired) q._save();
    return q;
  }

  /// The docs as gui.json's list gives them, every `at` 0 (spec §10.1); written at once when [dir] is set, so the
  /// new phrase ids stay.
  factory QuickPrefs.migrate(List<StripItem> legacy, {String? dir, DateTime Function() clock = DateTime.now}) {
    final m = _migrateLists(legacy);
    final q = QuickPrefs._(dir, clock, legacy, m.phrases, m.keys, KeyLayout.fallback, [], {},
        {for (final n in _allNames) n: 0});
    q._save();
    return q;
  }

  final String? _dir;
  final DateTime Function() _clock;
  final List<StripItem> _legacy;
  List<StripItem> _phrases;
  List<KeyAction> _keys;
  KeyLayout _layout; // as stored; [layout] is it cleaned
  KeyLayout? _cleaned;
  List<String> _stars;
  Usage _usage;
  Map<String, Usage> _others = const {};
  final Map<String, int> _at;

  /// Per doc, the lowest `at` a local change may take: the service's `at` + 1 (spec §10.3), set by the sync.
  final Map<String, int> floor = {};

  /// Told the doc's name after each local change (not after [adopt]): the sync sends it.
  void Function(String name)? onLocal;

  /// Where later writes go, when set: MainState points it at its data dir's device folder, so a device id that turns
  /// up after the start, or a moved data root, is followed as gui.json is. Null result: nothing is written (R22).
  String? Function()? dirOf;

  /// Told when quick.json could not be written.
  void Function(Object error)? onSaveError;

  /// 常用语和命令, in strip order.
  List<StripItem> get phrases => _phrases;

  /// 按键动作, in menu order.
  List<KeyAction> get keys => _keys;

  /// The key bar's layout, cleaned against [keys].
  KeyLayout get layout => _cleaned ??= _layout.cleaned({for (final a in _keys) a.id});

  /// Refs (`p:` / `k:`) in the order they were starred.
  List<String> get stars => _stars;

  /// This device's own counts.
  Usage get usage => _usage;

  /// The other devices' counts, by device id (filled by the sync).
  Map<String, Usage> get others => _others;

  int atOf(String name) => _at[name] ?? 0;

  QuickDoc docOf(String name) => QuickDoc(atOf(name), switch (name) {
        'phrases' => [for (final p in _phrases) p.toJson()],
        'keys' => [for (final a in _keys) a.toJson()],
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

  /// The 按键动作 replaced (an id kept once); a deleted action's star and layout cells go with it (Ruling 7).
  void setKeys(List<KeyAction> v) {
    final seen = <String>{};
    final gone = {for (final a in _keys) 'k:${a.id}'};
    _keys = [for (final a in v) if (seen.add(a.id)) a];
    gone.removeAll(_keys.map((a) => a.ref));
    final names = ['keys'];
    if (_layout.rows.any((r) => r.any(gone.contains))) {
      _layout = _without(_layout, gone);
      names.add('layout');
    }
    if (_dropStars('k:', {for (final a in _keys) a.ref})) names.add('stars');
    _commit(names);
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
    switch (name) {
      case 'phrases':
        final p = _phrasesFrom(d.data);
        _phrases = p == null ? _migrateLists(_legacy).phrases : _withIds(p);
      case 'keys':
        _keys = _keysFrom(d.data) ?? _migrateLists(_legacy).keys;
      case 'layout':
        _layout = _layoutFrom(d.data) ?? KeyLayout.fallback;
      case 'stars':
        _stars = _starsFrom(d.data) ?? [];
      case 'usage':
        _usage = _usageFrom(d.data) ?? {};
      default:
        return;
    }
    _at[name] = d.at;
    _cleaned = null;
    _save();
    notifyListeners();
  }

  void setOthers(Map<String, Usage> v) {
    _others = Map.of(v);
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
      _at[n] = max(now, floor[n] ?? 0);
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
    } catch (e) {
      onSaveError?.call(e);
    }
  }
}
