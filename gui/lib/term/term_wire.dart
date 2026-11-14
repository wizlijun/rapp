// Wire messages of the terminal worker (`rust/term/src/proto.rs`): one JSON object per line.

class TermPane {
  final String id, win, window, title, command;
  final int cols, rows;
  final bool dead, active;
  const TermPane({
    required this.id,
    this.win = '',
    required this.window,
    required this.title,
    required this.command,
    required this.cols,
    required this.rows,
    required this.dead,
    this.active = false,
  });

  /// The pane id without its `%`.
  int get number => int.tryParse(id.startsWith('%') ? id.substring(1) : id) ?? 0;
}

sealed class TermOut {
  const TermOut();
}

class TermHello extends TermOut {
  final int v;
  final String backend;
  const TermHello(this.v, this.backend);
}

class TermPanes extends TermOut {
  final List<TermPane> panes;
  const TermPanes(this.panes);
}

class TermScreen extends TermOut {
  final String pane;
  final int rev, cols, rows, cx, cy;
  final bool cursor, alt, full, more;
  final List<(int, String)> lines;
  final int? hist, limit;
  final String shape;
  final Set<int> wrapped;
  const TermScreen({
    required this.pane,
    required this.rev,
    required this.cols,
    required this.rows,
    required this.cx,
    required this.cy,
    required this.cursor,
    required this.alt,
    required this.full,
    required this.more,
    required this.lines,
    this.hist,
    this.limit,
    this.shape = '',
    this.wrapped = const {},
  });
}

class TermHistory extends TermOut {
  final String pane;
  final int before;
  final List<String> lines;
  final int? hist;
  final Set<int> wrapped;
  const TermHistory({required this.pane, required this.before, required this.lines, this.hist, this.wrapped = const {}});
}

class TermPasted extends TermOut {
  final bool ok;
  final String? error;
  const TermPasted(this.ok, this.error);
}

class TermError extends TermOut {
  final String error;
  const TermError(this.error);
}

/// Null for anything that is not a well-formed message, so one bad line never throws.
TermOut? parseTermOut(Object? json) {
  if (json is! Map) return null;
  try {
    return _parse(json);
  } catch (_) {
    return null;
  }
}

class _Bad implements Exception {
  const _Bad();
}

T _req<T>(Map m, String k) {
  final v = m[k];
  if (v is T) return v;
  throw const _Bad();
}

T? _opt<T>(Map m, String k) {
  final v = m[k];
  if (v == null) return null;
  if (v is T) return v;
  throw const _Bad();
}

Set<int> _ints(Map m, String k) {
  final v = m[k];
  if (v == null) return {};
  if (v is! List) throw const _Bad();
  return {for (final e in v) e is int ? e : throw const _Bad()};
}

TermOut? _parse(Map m) {
  switch (m['t']) {
    case 'hello':
      return TermHello(_req<int>(m, 'v'), _req<String>(m, 'backend'));
    case 'panes':
      return TermPanes([
        for (final p in _req<List>(m, 'panes'))
          if (p is Map)
            TermPane(
              id: _req<String>(p, 'id'),
              win: _opt<String>(p, 'win') ?? '',
              window: _req<String>(p, 'window'),
              title: _req<String>(p, 'title'),
              command: _req<String>(p, 'command'),
              cols: _req<int>(p, 'cols'),
              rows: _req<int>(p, 'rows'),
              dead: _req<bool>(p, 'dead'),
              active: _opt<bool>(p, 'active') ?? false,
            )
          else
            throw const _Bad(),
      ]);
    case 'screen':
      return TermScreen(
        pane: _req<String>(m, 'pane'),
        rev: _req<int>(m, 'rev'),
        cols: _req<int>(m, 'cols'),
        rows: _req<int>(m, 'rows'),
        cx: _req<int>(m, 'cx'),
        cy: _req<int>(m, 'cy'),
        cursor: _req<bool>(m, 'cursor'),
        alt: _req<bool>(m, 'alt'),
        full: _req<bool>(m, 'full'),
        more: _req<bool>(m, 'more'),
        lines: [
          for (final l in _req<List>(m, 'lines'))
            if (l is List && l.length == 2 && l[0] is int && l[1] is String) (l[0] as int, l[1] as String) else throw const _Bad(),
        ],
        hist: _opt<int>(m, 'hist'),
        limit: _opt<int>(m, 'limit'),
        shape: _opt<String>(m, 'shape') ?? '',
        wrapped: _ints(m, 'wrapped'),
      );
    case 'history':
      return TermHistory(
        pane: _req<String>(m, 'pane'),
        before: _req<int>(m, 'before'),
        lines: [for (final l in _req<List>(m, 'lines')) l is String ? l : throw const _Bad()],
        hist: _opt<int>(m, 'hist'),
        wrapped: _ints(m, 'wrapped'),
      );
    case 'pasted':
      return TermPasted(_req<bool>(m, 'ok'), _opt<String>(m, 'error'));
    case 'error':
      return TermError(_req<String>(m, 'error'));
  }
  return null;
}

Map<String, Object?> viewMsg(String? pane, int cols, int rows) => {'t': 'view', 'pane': pane, 'cols': cols, 'rows': rows};
Map<String, Object?> ackMsg(int rev) => {'t': 'ack', 'rev': rev};
Map<String, Object?> historyReq(String pane, int before, int lines) =>
    {'t': 'history', 'pane': pane, 'before': before, 'lines': lines};
Map<String, Object?> refitMsg(String pane, int cols, int rows) => {'t': 'refit', 'pane': pane, 'cols': cols, 'rows': rows};

/// Pane id -> tab text: `<window> <command>`, or `<window>.<pane> <command>` when the window has several panes;
/// numbered from 1 in the device's order; dead panes get ` · 已退出`. Old devices send no `win`: then the window name groups.
Map<String, String> tabLabels(List<TermPane> panes) {
  String key(TermPane p) => p.win.isEmpty ? p.window : p.win;
  final order = <String>[];
  final members = <String, List<TermPane>>{};
  for (final p in panes) {
    (members[key(p)] ??= (() {
      order.add(key(p));
      return <TermPane>[];
    })())
        .add(p);
  }
  final out = <String, String>{};
  for (final p in panes) {
    final k = key(p);
    final w = order.indexOf(k) + 1;
    final group = members[k]!;
    final head = group.length > 1 ? '$w.${group.indexOf(p) + 1}' : '$w';
    out[p.id] = '$head ${p.command}${p.dead ? ' · 已退出' : ''}';
  }
  return out;
}
