import 'dart:convert';
import 'dart:io';

import '../paths.dart' show DataDir;

/// The app state rules library (spec §5.2, §5.3, §7): built-in packs plus the user's own
/// (`shared/state_rules/*.json`), `extends`, patches, and the choice of one pack per app.
/// Pure Dart. Task 11 sends [ChosenRules.json] to the host.

/// A pack, resolved, may not be bigger than this many bytes (wire type 43).
const stateRulesLimit = 65536;

/// A single file of "mine" may not be bigger than this.
const _fileLimit = 1 << 20;

enum RulesLayer { builtin, mine }

class SignalTally {
  const SignalTally(this.tested, this.seen, this.reported, this.untested);
  final int tested, seen, reported, untested;
}

class ChosenRules {
  const ChosenRules(
      {required this.id,
      required this.rev,
      required this.layer,
      required this.patched,
      required this.json,
      required this.tally});
  final String id;
  final int rev;
  final RulesLayer layer;
  final bool patched;

  /// The resolved pack: extends and mine patches applied, variants kept.
  final String json;
  final SignalTally tally;
}

/// Same rule as Swift `RuleValue.merged`: objects merge by key, `null` deletes, arrays and scalars replace.
Object? mergeRules(Object? base, Object? patch) {
  if (base is Map && patch is Map) {
    final out = <String, Object?>{for (final e in base.entries) '${e.key}': e.value};
    for (final e in patch.entries) {
      final k = '${e.key}';
      if (e.value == null) {
        out.remove(k);
      } else {
        out[k] = out.containsKey(k) ? mergeRules(out[k], e.value) : _strip(e.value);
      }
    }
    return out;
  }
  return patch is Map ? _strip(patch) : patch;
}

/// A value taken as new: `null`s inside objects mean nothing there, so they are dropped like a merge onto nothing.
Object? _strip(Object? v) {
  if (v is Map) {
    return <String, Object?>{
      for (final e in v.entries)
        if (e.value != null) '${e.key}': _strip(e.value)
    };
  }
  return v;
}

class _Entry {
  _Entry(this.pack, this.layer, this.name);
  final Map<String, Object?> pack;
  final RulesLayer layer;
  final String name; // file name for mine, '' for built-in
  String get id => pack['id'] as String;
  int get rev => _rev(pack['rev']);
}

int _rev(Object? v) => v is num ? v.toInt() : 0;

bool _major1(Object? format) => format is String && (format == '1' || format.startsWith('1.'));

class StateRulesLibrary {
  StateRulesLibrary._(this._entries, this._patches, this.errors);

  final Map<String, _Entry> _entries; // best entry per id
  final Map<String, List<Map<String, Object?>>> _patches; // patchOf id → patches in file-name order
  /// Unreadable "mine" files, `'<file>: <reason>'`, for display only.
  final List<String> errors;

  /// [builtinJson] is the asset (`{"version":1,"packs":[…]}`); [mineFiles] maps file name → content.
  static StateRulesLibrary parse(String? builtinJson, Map<String, String> mineFiles) {
    final entries = <String, _Entry>{};
    final patches = <String, List<Map<String, Object?>>>{};
    final errors = <String>[];

    void offer(_Entry e) {
      final cur = entries[e.id];
      // A larger rev wins; a tie goes to mine.
      // Files come in name order, so at a full tie the first file name stays.
      if (cur == null || e.rev > cur.rev || (e.rev == cur.rev && e.layer == RulesLayer.mine && cur.layer == RulesLayer.builtin)) {
        entries[e.id] = e;
      }
    }

    if (builtinJson != null) {
      try {
        final root = jsonDecode(builtinJson);
        final list = root is Map ? root['packs'] : null;
        if (list is List) {
          for (final p in list) {
            if (p is Map && _major1(p['format']) && p['id'] is String && (p['id'] as String).isNotEmpty) {
              offer(_Entry(_asMap(p), RulesLayer.builtin, ''));
            }
          }
        }
      } catch (_) {}
    }

    for (final name in (mineFiles.keys.toList()..sort())) {
      try {
        final v = jsonDecode(mineFiles[name]!);
        if (_deeper(v, 64)) throw 'too deep';
        if (v is! Map) throw '顶层不是对象';
        if (!_major1(v['format'])) throw '格式版本不认识';
        if (v.containsKey('patchOf')) {
          final of = v['patchOf'];
          if (of is! String || of.isEmpty) throw 'patchOf 不是包名';
          if (v['patch'] is! Map) throw '缺少 patch';
          (patches[of] ??= []).add(_asMap(v['patch'] as Map));
        } else {
          final id = v['id'];
          if (id is! String || id.isEmpty) throw '缺少 id';
          offer(_Entry(_asMap(v), RulesLayer.mine, name));
        }
      } catch (e) {
        errors.add('$name: $e');
      }
    }
    return StateRulesLibrary._(entries, patches, errors);
  }

  static bool _deeper(Object? v, int left) {
    if (left < 0) return true;
    if (v is Map) return v.values.any((x) => _deeper(x, left - 1));
    if (v is List) return v.any((x) => _deeper(x, left - 1));
    return false;
  }

  static Map<String, Object?> _asMap(Map m) => {for (final e in m.entries) '${e.key}': e.value};

  /// Reads `*.json` of [DataDir.stateRulesDir] (not recursive; a file over 1 MB is an error, not read).
  static Future<StateRulesLibrary> load(DataDir data, String? builtinJson) async {
    final files = <String, String>{};
    final errs = <String>[];
    try {
      final dir = Directory(data.stateRulesDir);
      if (await dir.exists()) {
        final found = <File>[];
        await for (final e in dir.list(followLinks: false)) {
          if (e is File && e.path.endsWith('.json')) found.add(e);
        }
        for (final f in found) {
          final name = f.uri.pathSegments.last;
          try {
            if (await f.length() > _fileLimit) {
              errs.add('$name: 文件超过 1 MB');
              continue;
            }
            files[name] = await f.readAsString();
          } catch (e) {
            errs.add('$name: $e');
          }
        }
      }
    } catch (_) {}
    final lib = parse(builtinJson, files);
    return StateRulesLibrary._(lib._entries, lib._patches, [...errs, ...lib.errors]);
  }

  /// Resolved pack of [id] (extends, then mine patches) and whether a mine patch was applied anywhere in
  /// the chain; null when missing, cyclic or unreadable. Never changes the stored packs.
  ({Map<String, Object?> pack, bool patched})? _resolve(String id, List<String> stack) {
    try {
      final e = _entries[id];
      if (e == null || stack.contains(id)) return null;
      Object? merged = e.pack;
      var patched = false;
      final base = e.pack['extends'];
      if (base != null) {
        if (base is! String) return null;
        final b = _resolve(base, [...stack, id]);
        if (b == null) return null;
        patched = b.patched;
        merged = mergeRules(b.pack, {...e.pack}..remove('extends'));
      }
      for (final p in _patches[id] ?? const <Map<String, Object?>>[]) {
        merged = mergeRules(merged, p);
        patched = true;
      }
      final out = {...(merged as Map<String, Object?>)}..remove('extends');
      return (pack: out, patched: patched);
    } catch (_) {
      return null;
    }
  }

  /// Whether [id] extends [base], directly or further up.
  bool _extends(String id, String base) {
    var cur = _entries[id]?.pack['extends'];
    for (var i = 0; cur is String && i < 32; i++) {
      if (cur == base) return true;
      cur = _entries[cur]?.pack['extends'];
    }
    return false;
  }

  ChosenRules? _chosen(String id) {
    final e = _entries[id];
    final res = _resolve(id, const []);
    if (e == null || res == null) return null;
    final m = res.pack;
    final String json;
    try {
      json = jsonEncode(m);
    } catch (_) {
      return null;
    }
    if (utf8.encode(json).length > stateRulesLimit) return null;
    final patched = res.patched;
    var t = 0, s = 0, r = 0, u = 0;
    final sigs = m['signals'];
    if (sigs is Map) {
      for (final v in sigs.values) {
        switch (v is Map ? v['status'] : null) {
          case 'tested':
            t++;
          case 'seen':
            s++;
          case 'reported':
            r++;
          default:
            u++;
        }
      }
    }
    return ChosenRules(
        id: id,
        rev: e.rev,
        layer: patched ? RulesLayer.mine : e.layer,
        patched: patched,
        json: json,
        tally: SignalTally(t, s, r, u));
  }

  /// [setting] is the app profile's stateRules: null (find by ids), 'off', or a pack id.
  ChosenRules? choose(String appId, String? setting) {
    if (setting == 'off') return null;
    if (setting != null) return _chosen(setting);
    final want = appId.toLowerCase();
    _Entry? best;
    for (final e in _entries.values) {
      final ids = _resolve(e.id, const [])?.pack['ids'];
      if (ids is! List || !ids.any((i) => i is String && i.toLowerCase() == want)) continue;
      if (_chosen(e.id) == null) continue;
      if (best == null || _beats(e, best)) best = e;
    }
    return best == null ? null : _chosen(best.id);
  }

  /// Larger rev, then mine, then the extender over its base, then the smaller file name (then id).
  bool _beats(_Entry a, _Entry b) {
    if (a.rev != b.rev) return a.rev > b.rev;
    if (a.layer != b.layer) return a.layer == RulesLayer.mine;
    if (_extends(a.id, b.id)) return true;
    if (_extends(b.id, a.id)) return false;
    final c = a.name.compareTo(b.name);
    return c != 0 ? c < 0 : a.id.compareTo(b.id) < 0;
  }
}
