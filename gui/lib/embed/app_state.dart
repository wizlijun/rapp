// What the host's state rules say an app's window is doing, read off its screen (the `app_state` report).
import 'dart:convert';

import '../hub_client.dart' show TermPs;

/// A report is at most this big (the host caps it too); a bigger one is skipped.
const appStateLimit = 4096;

const _states = {'working', 'done', 'blocked', 'idle'};
const _healths = {'ok', 'switched', 'unfit', 'invalid'};

class AppState {
  const AppState({
    this.state,
    this.kind,
    this.pack,
    this.appVersion,
    this.error,
    this.rev,
    this.by = const [],
    this.variants = const [],
    this.sure = false,
    this.health = 'ok',
    this.counts = const {},
  });

  /// `working`, `done`, `blocked`, `idle`; null when the rules do not apply (or the word is unknown).
  final String? state, kind, pack, appVersion, error;
  final int? rev;
  final List<String> by, variants;

  /// Every flag behind this state is `tested`: only then does a block count as 需要你.
  final bool sure;

  /// `ok`, `switched` (the host changed variant), `unfit` (nothing fits), `invalid` (the pack is unreadable).
  final String health;
  final Map<String, int> counts;

  /// Null for bad JSON, a non-object, or a report over [appStateLimit]; never throws.
  static AppState? parse(String json) {
    try {
      if (json.length > appStateLimit || utf8.encode(json).length > appStateLimit) return null;
      final m = jsonDecode(json);
      if (m is! Map) return null;
      String? str(Object? v) => v is String ? v : null;
      List<String> strs(Object? v) => v is List ? [for (final x in v) if (x is String) x] : const [];
      final s = m['state'];
      final h = m['health'];
      final c = m['counts'];
      return AppState(
        state: s is String && _states.contains(s) ? s : null,
        kind: str(m['kind']),
        pack: str(m['pack']),
        appVersion: str(m['appVersion']),
        error: str(m['error']),
        rev: m['rev'] is int ? m['rev'] as int : null,
        by: strs(m['by']),
        variants: strs(m['variants']),
        sure: m['sure'] == true,
        health: h is String && _healths.contains(h) ? h : 'ok',
        counts: c is Map ? {for (final e in c.entries) if (e.key is String && e.value is int) e.key as String: e.value as int} : const {},
      );
    } catch (_) {
      return null;
    }
  }

  /// The state as a program status, so the lamp and words are the terminals' own.
  TermPs? get ps => state == null ? null : TermPs(state!, kind: kind);

  /// The rules may be out of date for this app: its screen no longer fits them, or they changed variant.
  bool get stale => health == 'unfit' || health == 'switched' || health == 'invalid';
}
