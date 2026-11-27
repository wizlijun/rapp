// Keeps the 快捷区 docs of [QuickPrefs] in step with the center service's `prefs` builtin (quick-row spec §10.2–
// §10.4). The rules are quick_merge.dart's; this file does the I/O, the timers and the bookkeeping in
// `<localDir>/quick-sync.json` (§10.1: not in git): which service (its store id), each doc's `synced` and the other
// devices' usage copied from the service.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../state/state_link.dart';
import 'quick_merge.dart';
import 'quick_prefs.dart';
import 'quick_usage.dart';

/// What the settings pages say (§10.5): synced with a service, only on this device (no service, or one without
/// `prefs`), or a service that cannot be reached right now (changes go up once it can).
enum QuickSyncStatus { local, synced, waiting }

/// How many times a doc is sent again after a 409 in one pass; then it waits for the next push, attach or change.
const _retries = 3;

QuickDoc? _docFrom(Object? j) {
  if (j is! Map) return null;
  final at = j['at'];
  if (at is! int || at < 0) return null;
  // The service's "none" (409 when nothing is stored) reads as none.
  if (at == 0 && j['data'] == null) return null;
  return QuickDoc(at, j['data']);
}

class QuickSync extends ChangeNotifier {
  QuickSync({
    required this.prefs,
    required this.localDir,
    required this.device,
    this.host,
    this.clock = DateTime.now,
    this.debounce = const Duration(seconds: 1),
    this.usageEvery = const Duration(minutes: 1),
  }) {
    _load();
    if (_others.isNotEmpty) prefs.setOthers(_otherUsage());
    prefs.onLocal = _onLocal;
  }

  final QuickPrefs prefs;

  /// Where `quick-sync.json` lives (the data dir's `local/`).
  final String localDir;

  /// This device's id; null: usage is never sent.
  final String? device;

  /// The id of the device the service runs on (Mac: the monitor's, iOS: the hub's); asked at each attach.
  final Future<String?> Function()? host;
  final DateTime Function() clock;

  /// Local changes made within this of each other go up together.
  final Duration debounce;

  /// This device's usage goes up at most once per this.
  final Duration usageEvery;

  QuickSyncStatus status = QuickSyncStatus.local;

  /// The device the service runs on, as `host()` said at the last attach (for the line on the settings pages).
  String? hostId;

  // ---- bookkeeping (quick-sync.json) ----
  String? _store;
  final Map<String, int> _synced = {};
  final Map<String, QuickDoc> _others = {};

  // ---- this attach ----
  StateLink? _link;
  bool _attaching = false;

  /// Bumped by every attach and detach; work started under another value drops its result.
  int _gen = 0;

  /// The service's copy of each doc as last heard (fetched, pushed by watch, returned by a 409, or what we put).
  final Map<String, QuickDoc?> _server = {};
  Future<void> _chain = Future.value();
  Timer? _debounce;
  Timer? _usageTimer;
  bool _usageDirty = false;
  bool _disposed = false;

  String get _file => '$localDir/quick-sync.json';

  int _now() => clock().millisecondsSinceEpoch;

  /// Fetches everything and runs §10.3 over the four docs; resolves when the pass is done. A link without the
  /// `prefs` builtin is the same as [detach] with `reachable: true`; a failed fetch leaves the status `waiting`.
  Future<void> attach(StateLink link) async {
    final gen = ++_gen;
    _stopTimers();
    _link = null;
    _server.clear();
    if (!link.prefs) {
      _attaching = false;
      _setStatus(QuickSyncStatus.local);
      return;
    }
    _attaching = true;
    String? id;
    try {
      id = await host?.call();
    } catch (_) {}
    if (gen != _gen) return;
    if (id != hostId) {
      hostId = id;
      notifyListeners();
    }
    Map<String, Object?> all;
    try {
      all = await link.prefsAll();
    } catch (_) {
      if (gen == _gen) {
        _attaching = false;
        _setStatus(QuickSyncStatus.waiting);
      }
      return;
    }
    if (gen != _gen) return;
    _attaching = false;
    final store = all['store'];
    if (store is! String || store.isEmpty) {
      _setStatus(QuickSyncStatus.waiting);
      return;
    }
    if (store != _store) {
      // Another service, or this one reinstalled: nothing is synced with it yet, so every doc is a first join.
      _store = store;
      _synced.clear();
      _others.clear();
    }
    for (final n in quickDocNames) {
      final fetched = _docFrom(all[n]);
      final heard = _server[n]; // a watch push that came while fetching
      _learn(n, heard != null && (fetched == null || heard.at > fetched.at) ? heard : fetched);
    }
    final usage = all['usage'];
    final own = usage is Map && device != null ? _docFrom(usage[device]) : null;
    _others
      ..clear()
      ..addAll({
        if (usage is Map)
          for (final e in usage.entries)
            if (e.key is String && e.key != device) e.key as String: ?_docFrom(e.value),
      });
    prefs.setOthers(_otherUsage());
    _link = link;
    _save();
    _setStatus(QuickSyncStatus.synced);
    final mine = prefs.atOf('usage');
    if (own != null && own.at > mine) {
      prefs.adopt('usage', own); // this device's own cell, kept by the service (e.g. after a reinstall)
    } else if (device != null && mine > 0 && own?.at != mine) {
      _usageChanged();
    }
    _queuePass();
    await _chain;
  }

  /// Stops syncing: `waiting` when the service cannot be reached, `local` when there is none or it has no `prefs`.
  /// Every timer stops; work in flight drops its result.
  void detach({required bool reachable}) {
    _gen++;
    _stopTimers();
    _link = null;
    _attaching = false;
    _setStatus(reachable ? QuickSyncStatus.local : QuickSyncStatus.waiting);
  }

  /// A watch event (`prefs.<name>` or `prefs.usage`); others are ignored, and so is anything while not attached.
  void onPush(Map<String, Object?> e) {
    if (_link == null && !_attaching) return;
    final what = e['what'];
    if (what is! String || !what.startsWith('prefs.')) return;
    final name = what.substring('prefs.'.length);
    final doc = _docFrom(e['doc']);
    if (doc == null) return;
    if (name == 'usage') {
      final dev = e['device'];
      if (dev is! String || dev.isEmpty || dev == device) return;
      _others[dev] = doc;
      prefs.setOthers(_otherUsage());
      _save();
      return;
    }
    if (!quickDocNames.contains(name)) return;
    if (doc.at <= (_synced[name] ?? 0)) return;
    final known = _server[name];
    if (known == null || doc.at > known.at) _learn(name, doc);
    // Also when the copy is already known (a 409 told us): a doc that ran out of retries waits for a push.
    if (_link != null) _queuePass();
  }

  // ---- inner ----

  void _onLocal(String name) {
    if (name == 'usage') {
      _usageChanged();
      return;
    }
    if (_link == null) return; // stays pending (at > synced); the next attach sends it
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      _debounce = null;
      _queuePass();
    });
  }

  void _queuePass() {
    final gen = _gen;
    _chain = _chain.then((_) => _pass(gen)).catchError((Object e) => debugPrint('quick_sync: $e'));
  }

  /// §10.3 over the four docs: a first join (all of them together, they depend on each other) for the docs that need
  /// one, the table for the rest. A doc whose PUT got a 409 goes round again with the returned copy, [_retries] times.
  Future<void> _pass(int gen) async {
    final rounds = <String, int>{};
    var todo = quickDocNames.toSet();
    while (todo.isNotEmpty) {
      if (gen != _gen || _link == null) return;
      final steps = _steps(todo);
      final again = <String>{};
      for (final n in quickDocNames) {
        final step = steps[n];
        if (step == null) continue;
        if (gen != _gen) return;
        switch (step) {
          case Keep():
            break;
          case Adopt(:final doc):
            prefs.adopt(n, doc);
            _synced[n] = doc.at;
            _learn(n, doc);
            _save();
          case Push():
            if (await _push(n, step, gen) && (rounds[n] = (rounds[n] ?? 0) + 1) <= _retries) again.add(n);
        }
      }
      todo = again;
    }
  }

  Map<String, MergeStep> _steps(Set<String> names) {
    final now = _now();
    final first = {
      for (final n in names)
        if (isFirstJoin(knownStore: _store, store: _store!, synced: _synced[n] ?? 0, server: _server[n])) n,
    };
    final joined = first.isEmpty
        ? const <String, MergeStep>{}
        : firstJoin(
            local: {for (final n in quickDocNames) n: prefs.docOf(n)},
            server: {
              for (final n in quickDocNames) n: ?_server[n],
            },
            nowMs: now,
          );
    return {
      for (final n in names)
        n: first.contains(n)
            ? joined[n] ?? const Keep()
            : decide(
                local: prefs.docOf(n),
                synced: _synced[n] ?? 0,
                server: _server[n],
                nowMs: now,
                log: (m) => debugPrint('quick_sync $n: $m'),
                name: n,
              ),
    };
  }

  /// Makes [step]'s doc the local one (a merge, or a new `at`) and puts it. True on a 409 (the service's copy is then
  /// known); a failed call leaves the doc pending, false.
  Future<bool> _push(String name, Push step, int gen) async {
    var doc = step.doc;
    // A doc never changed here (at 0) still needs a real time once it is the service's copy, or every later change
    // here would look like a first join again and be merged rather than sent.
    if (doc.at == 0) doc = QuickDoc(max(_now(), step.base + 1), doc.data);
    final cur = prefs.docOf(name);
    if (cur.at != doc.at || jsonEncode(cur.data) != jsonEncode(doc.data)) prefs.adopt(name, doc);
    final sent = prefs.docOf(name);
    final QuickDoc? conflict;
    try {
      conflict = await _link!.putPref(name, at: sent.at, base: step.base, data: sent.data);
    } catch (e) {
      debugPrint('quick_sync $name: put failed ($e)');
      return false;
    }
    if (gen != _gen) return false;
    if (conflict == null) {
      _synced[name] = sent.at;
      _learn(name, sent);
      _save();
      return false;
    }
    _learn(name, conflict.at == 0 && conflict.data == null ? null : conflict);
    return true;
  }

  /// [d] is the service's copy of [name]; a local change goes above it (§10.3).
  void _learn(String name, QuickDoc? d) {
    _server[name] = d;
    if (d != null) prefs.floor[name] = max(prefs.floor[name] ?? 0, d.at + 1);
  }

  /// At most one usage PUT per [usageEvery]: the first change goes at once, later ones at the end of the window.
  void _usageChanged() {
    if (device == null || _link == null) return; // the next attach compares and sends
    _usageDirty = true;
    if (_usageTimer != null) return;
    _sendUsage();
    _usageTimer = Timer(usageEvery, _usageTick);
  }

  void _usageTick() {
    _usageTimer = null;
    if (!_usageDirty || _link == null) return;
    _sendUsage();
    _usageTimer = Timer(usageEvery, _usageTick);
  }

  /// A failure is not retried by a timer: the next change, or the next attach, sends it.
  Future<void> _sendUsage() async {
    _usageDirty = false;
    final d = prefs.docOf('usage');
    try {
      await _link!.putUsage(device!, at: d.at, data: d.data);
    } catch (e) {
      debugPrint('quick_sync usage: put failed ($e)');
    }
  }

  Map<String, Usage> _otherUsage() => {for (final e in _others.entries) e.key: usageFromJson(e.value.data)};

  void _setStatus(QuickSyncStatus s) {
    if (s == status) return;
    status = s;
    if (!_disposed) notifyListeners();
  }

  void _stopTimers() {
    _debounce?.cancel();
    _debounce = null;
    _usageTimer?.cancel();
    _usageTimer = null;
    _usageDirty = false;
  }

  /// A missing or unreadable file is a device that never synced.
  void _load() {
    try {
      final j = jsonDecode(File(_file).readAsStringSync());
      if (j is! Map) return;
      final store = j['store'];
      if (store is String && store.isNotEmpty) _store = store;
      final synced = j['synced'];
      if (synced is Map) {
        for (final n in quickDocNames) {
          final v = synced[n];
          if (v is int && v >= 0) _synced[n] = v;
        }
      }
      final others = j['others'];
      if (others is Map) {
        for (final e in others.entries) {
          if (e.key is String && e.key != device) {
            if (_docFrom(e.value) case final d?) _others[e.key as String] = d;
          }
        }
      }
    } catch (_) {}
  }

  /// Written to a `.tmp` and renamed over.
  void _save() {
    try {
      Directory(localDir).createSync(recursive: true);
      final tmp = File('$_file.tmp');
      tmp.writeAsStringSync(jsonEncode({
        'store': _store,
        'synced': {for (final n in quickDocNames) n: _synced[n] ?? 0},
        'others': {for (final e in _others.entries) e.key: {'at': e.value.at, 'data': e.value.data}},
      }));
      tmp.renameSync(_file);
    } catch (e) {
      debugPrint('quick_sync: cannot write quick-sync.json ($e)');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _stopTimers();
    _link = null;
    if (prefs.onLocal == _onLocal) prefs.onLocal = null;
    super.dispose();
  }
}
