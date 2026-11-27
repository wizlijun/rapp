// 全局设置 → 键盘布局 (quick-row spec §8, cmd-menu design): the two rows of the key bar. Select a cell, replace it, delete
// it, drag it within its row, or add one at a row's end; 恢复默认布局; and the sync line.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../embed/key_bar.dart';
import '../embed/key_bar_keys.dart';
import '../quick/key_layout.dart';
import 'quick_sync_line.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';

Future<void> openLayoutPage(BuildContext context, MainState state) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => LayoutPage(state: state)));

class LayoutPage extends StatelessWidget {
  const LayoutPage({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(backgroundColor: t.bg, foregroundColor: t.text, title: Text('键盘布局', style: TextStyle(color: t.text))),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
          _LayoutEditor(state: state),
          QuickSyncLine(state: state),
        ]),
      ),
    );
  }
}

/// Whether row [r] (0 or 1) of [rows] can take one more cell: 10 at most, and 9 in row 1 while row 2 holds keys (⋯ joins
/// it). Row 2 gaining its first cell is what makes row 1 lose a place, so it also needs row 1 to hold 9 or fewer.
bool layoutRowHasRoom(List<List<String>> rows, int r) {
  if (r == 0) return rows[0].length < (rows[1].isEmpty ? keyRowMax : keyRowMax - 1);
  return rows[1].length < keyRowMax && (rows[1].isNotEmpty || rows[0].length <= keyRowMax - 1);
}

class _LayoutEditor extends StatefulWidget {
  const _LayoutEditor({required this.state});
  final MainState state;

  @override
  State<_LayoutEditor> createState() => _LayoutEditorState();
}

class _LayoutEditorState extends State<_LayoutEditor> {
  /// The selected cell (row, index), or the row whose ＋ is active; at most one of them.
  (int, int)? _sel;
  int? _adding;

  /// The rows as last drawn: when the layout is not these any more, the selection is let go.
  List<List<String>>? _drawn;

  MainState get _s => widget.state;

  static bool _same(List<List<String>> a, List<List<String>> b) =>
      a.length == b.length && [for (var r = 0; r < a.length; r++) listEquals(a[r], b[r])].every((x) => x);

  List<List<String>> _rows() => [for (final r in _s.quick.layout.rows) List<String>.of(r)];

  void _commit(List<List<String>> rows) {
    // The caps are the ＋ buttons' job; this keeps a stray combination from reaching the bar.
    if (rows[0].length > (rows[1].isEmpty ? keyRowMax : keyRowMax - 1) || rows[1].length > keyRowMax) return;
    _s.setKeyLayout(KeyLayout(rows));
  }

  void _pick(String id) {
    final rows = _rows();
    final sel = _sel, add = _adding;
    if (sel != null && sel.$2 < rows[sel.$1].length) {
      rows[sel.$1][sel.$2] = id;
      // The key is wherever it was: it moves here, never twice (ruling: the old spot goes).
      for (var r = 0; r < 2; r++) {
        for (var i = rows[r].length - 1; i >= 0; i--) {
          if (rows[r][i] == id && !(r == sel.$1 && i == sel.$2)) rows[r].removeAt(i);
        }
      }
    } else if (add != null) {
      for (final r in rows) {
        r.remove(id);
      }
      rows[add].add(id);
    } else {
      return;
    }
    _commit(rows);
    setState(() {
      _sel = null;
      _adding = null;
    });
  }

  void _delete() {
    final sel = _sel;
    if (sel == null) return;
    final rows = _rows();
    if (sel.$2 < rows[sel.$1].length) rows[sel.$1].removeAt(sel.$2);
    _commit(rows);
    setState(() => _sel = null);
  }

  void _move(int row, int from, int to) {
    final rows = _rows();
    if (from >= rows[row].length || to >= rows[row].length || from == to) return;
    rows[row].insert(to, rows[row].removeAt(from));
    _commit(rows);
    setState(() {
      _sel = null;
      _adding = null;
    });
  }

  String _faceOf(String id) => barKeys[id]?.label ?? id;

  Widget _cell(RappTokens t, int row, int i, String id) {
    final face = SizedBox(height: keyBarKeyHeight, child: KeyFace(label: _faceOf(id), lit: _sel == (row, i), onTap: () => setState(() {
      _sel = _sel == (row, i) ? null : (row, i);
      _adding = null;
    })));
    return DragTarget<(int, int)>(
      onWillAcceptWithDetails: (d) => d.data.$1 == row && d.data.$2 != i,
      onAcceptWithDetails: (d) => _move(row, d.data.$2, i),
      builder: (context, _, _) => Draggable<(int, int)>(
        key: Key('layout-cell-$row-$i'),
        data: (row, i),
        axis: Axis.horizontal,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(width: 64, height: keyBarKeyHeight, child: KeyFace(label: _faceOf(id), lit: true)),
        ),
        childWhenDragging: Opacity(opacity: .3, child: face),
        child: face,
      ),
    );
  }

  Widget _row(RappTokens t, List<List<String>> rows, int r) {
    final shown = [...rows[r], if (r == 0 && rows[1].isNotEmpty) 'more'];
    final room = layoutRowHasRoom(rows, r);
    final active = _adding == r;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text('第 ${r + 1} 行', style: TextStyle(color: t.muted, fontSize: t.textSize - 2)),
      ),
      SizedBox(
        height: keyBarKeyHeight,
        child: Row(children: [
          Expanded(
            child: KeyBarRow(
              ids: shown,
              cell: (id) {
                if (id == 'more') {
                  // Drawn where the bar will draw it; not selectable, not deletable.
                  return Opacity(
                      key: const Key('layout-more'), opacity: .5, child: KeyFace(label: barKeys['more']!.label));
                }
                return _cell(t, r, rows[r].indexOf(id), id);
              },
            ),
          ),
          const SizedBox(width: keyBarGap),
          SizedBox(
            width: keyBarKeyHeight,
            child: Opacity(
              opacity: room ? 1 : .4,
              child: KeyFace(
                key: Key('layout-add-$r'),
                label: '＋',
                lit: active,
                onTap: room
                    ? () => setState(() {
                          _adding = active ? null : r;
                          _sel = null;
                        })
                    : null,
              ),
            ),
          ),
        ]),
      ),
      if (r == 1 && rows[1].isEmpty && rows[0].length >= keyRowMax)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('第 1 行满 10 格时，第 2 行加不了：⋯ 要占第 1 行一格',
              key: const Key('layout-add-1-note'), style: TextStyle(color: t.muted, fontSize: t.textSize - 2)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final rows = _rows();
    // A layout changed since the last draw (恢复默认, another device's, a deleted action's cell gone): the selected
    // place may hold another key now, or be past the row's end; let go of it, and of a ＋ that was on.
    final drawn = _drawn;
    if (drawn != null && !_same(drawn, rows)) {
      _sel = null;
      _adding = null;
    }
    _drawn = rows;
    final candidates = [
      for (final id in barKeys.keys)
        if (id != 'more') id,
    ];
    final target = _sel != null ? '点下面的键换掉这一格' : _adding != null ? '点下面的键加到第 ${_adding! + 1} 行末尾' : '先点一格或行末的＋';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _row(t, rows, 0),
      const SizedBox(height: 8),
      _row(t, rows, 1),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text(target, key: const Key('layout-hint'), style: TextStyle(color: t.muted))),
        if (_sel != null) RappButton.secondary(key: const Key('layout-delete'), label: '删除这一格', onPressed: _delete),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final id in candidates)
          SizedBox(width: 64, height: 38, child: KeyFace(key: Key('layout-pick-$id'), label: _faceOf(id), onTap: () => _pick(id))),
      ]),
      const SizedBox(height: 8),
      Text('每行最多 10 格；第 2 行有键时，第 1 行最多 9 格，⋯ 自动排在第 1 行末尾。拖动只能在同一行里换位，换行请删掉再到另一行加。',
          style: TextStyle(color: t.muted)),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: RappButton.quiet(
            key: const Key('keys-restore-layout'),
            label: '恢复默认布局',
            onPressed: () {
              _s.setKeyLayout(KeyLayout.fallback);
              setState(() {
                _sel = null;
                _adding = null;
              });
            }),
      ),
    ]);
  }
}
