// The key bar's layout: two rows of cells, each a `barKeys` id (never `more`) (quick-row spec §8; the `k:` cells of the
// old 按键动作 are gone, cmd-menu design).
// Pure data; [cleaned] makes any stored layout drawable.
import '../embed/key_bar_keys.dart';

const keyRowMax = 10;

class KeyLayout {
  const KeyLayout(this.rows);

  final List<List<String>> rows;

  static const fallback = KeyLayout([
    ['tab', 'esc', 'cc', 'bksp', 'enter', 'up'],
    ['copy', 'paste', 'cmdt', 'cmd', 'ctrl', 'pgup', 'pgdn', 'left', 'down', 'right'],
  ]);

  Map<String, Object?> toJson() => {
        'rows': [for (final r in rows) List<String>.of(r)],
      };

  /// Anything that is not a list of rows of strings falls back; non-string cells are dropped.
  static KeyLayout fromJson(Object? j) {
    final rows = j is Map ? j['rows'] : null;
    if (rows is! List) return fallback;
    return KeyLayout([
      for (final r in rows.take(2)) r is List ? [for (final c in r) if (c is String) c] : <String>[],
      ...List.generate(rows.length >= 2 ? 0 : 2 - rows.length, (_) => <String>[]),
    ]);
  }

  /// Drops unknown cells (an old `k:` one too), `more` and repeats (an id is kept only once, first place wins), caps
  /// the rows (10, and 9 for row 1 when row 2 holds keys, since ⋯ joins it); empty rows both → [fallback].
  KeyLayout cleaned() {
    final seen = <String>{};
    List<String> clean(List<String> row) => [
          for (final c in row)
            if (c != 'more' && barKeys.containsKey(c) && seen.add(c)) c,
        ];
    final a = clean(rows.isNotEmpty ? rows[0] : const []);
    final b = clean(rows.length > 1 ? rows[1] : const []).take(keyRowMax).toList();
    if (a.isEmpty && b.isEmpty) return fallback;
    return KeyLayout([a.take(b.isEmpty ? keyRowMax : keyRowMax - 1).toList(), b]);
  }

  bool get isDefault {
    if (rows.length != fallback.rows.length) return false;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].join(',') != fallback.rows[i].join(',')) return false;
    }
    return true;
  }
}
