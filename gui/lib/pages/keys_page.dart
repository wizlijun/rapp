// 按键 settings (quick-row spec §6.4): the 按键动作 list (drag to reorder, swipe to delete, tap to edit, ★ to put on the
// first row), 新增 and 恢复默认按键动作; the sheet that edits one action; and the 键盘布局 section (§8): select a cell, replace
// it, delete it, drag it within its row, or add one at a row's end.
import 'package:flutter/material.dart';

import '../embed/key_bar.dart';
import '../embed/key_bar_keys.dart';
import '../embed/strip_tools.dart';
import '../quick/key_actions.dart';
import '../quick/key_layout.dart';
import 'quick_sync_line.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';

Future<void> openKeysPage(BuildContext context, MainState state) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => KeysPage(state: state)));

/// The edit sheet: [start] to change (id and per-tool chords are kept by the caller), null for a new one.
/// Null back when cancelled. The result carries [start]'s id and `per`, or a fresh [quickId].
Future<KeyAction?> editKeyAction(BuildContext context, {KeyAction? start}) => showModalBottomSheet<KeyAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RappTokens.of(context).bg,
      builder: (_) => _KeyActionEditor(start: start),
    );

const _letters = 'abcdefghijklmnopqrstuvwxyz';
const _digits = '0123456789';

class _KeyActionEditor extends StatefulWidget {
  const _KeyActionEditor({this.start});
  final KeyAction? start;

  @override
  State<_KeyActionEditor> createState() => _KeyActionEditorState();
}

class _KeyActionEditorState extends State<_KeyActionEditor> {
  late final _name = TextEditingController(text: widget.start?.label ?? '');
  late bool _ctrl = widget.start?.chord.ctrl ?? false;
  late bool _alt = widget.start?.chord.alt ?? false;
  late bool _shift = widget.start?.chord.shift ?? false;
  late bool _cmd = widget.start?.chord.cmd ?? false;
  late String? _key = widget.start?.chord.key;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ok => _name.text.trim().isNotEmpty && _key != null;

  KeyAction _build() => KeyAction(
        widget.start?.id ?? quickId(),
        label: _name.text.trim(),
        chord: Chord(_key!, ctrl: _ctrl, alt: _alt, shift: _shift, cmd: _cmd),
        per: widget.start?.per ?? const {},
      );

  Widget _mod(String id, String face, bool on, ValueChanged<bool> set) => FilterChip(
        key: Key('keyact-mod-$id'),
        label: Text(face),
        selected: on,
        onSelected: (v) => setState(() => set(v)),
      );

  Widget _pick(String k, String face) => ChoiceChip(
        key: Key('keyact-key-$k'),
        label: Text(face),
        selected: _key == k,
        onSelected: (_) => setState(() => _key = k),
      );

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.start == null ? '新增按键动作' : '编辑按键动作', style: TextStyle(color: t.text, fontSize: t.textSize + 2)),
          const SizedBox(height: 12),
          TextField(
            key: const Key('keyact-name'),
            controller: _name,
            style: TextStyle(color: t.text),
            decoration: const InputDecoration(hintText: '名字（键上显示的字）'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Text('修饰键', style: TextStyle(color: t.muted)),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _mod('ctrl', '⌃', _ctrl, (v) => _ctrl = v),
            _mod('alt', '⌥', _alt, (v) => _alt = v),
            _mod('shift', '⇧', _shift, (v) => _shift = v),
            _mod('cmd', '⌘', _cmd, (v) => _cmd = v),
          ]),
          const SizedBox(height: 12),
          Text('键', style: TextStyle(color: t.muted)),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in _letters.split('')) _pick(c, c.toUpperCase()),
            for (final c in _digits.split('')) _pick(c, c),
            for (final n in chordNamedKeys) _pick(n, barKeys[n]!.label),
          ]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            RappButton.quiet(label: '取消', onPressed: () => Navigator.of(context).pop()),
            const SizedBox(width: 8),
            RappButton.primary(
              key: const Key('keyact-save'),
              label: '保存',
              onPressed: _ok ? () => Navigator.of(context).pop(_build()) : null,
            ),
          ]),
        ]),
      ),
    );
  }
}

/// `Codex ⌃R · Agy 无`: the tools whose chord differs from the plain one.
String _perSubtitle(KeyAction a) => [
      for (final t in agentTools)
        if (a.per.containsKey(t.id)) '${t.name} ${a.per[t.id]?.label ?? '无'}',
    ].join(' · ');

class KeysPage extends StatelessWidget {
  const KeysPage({super.key, required this.state});
  final MainState state;

  Future<void> _edit(BuildContext context, int? i) async {
    final l = List.of(state.quick.keys);
    final r = await editKeyAction(context, start: i == null ? null : l[i]);
    if (r == null) return;
    if (i == null) {
      l.add(r);
    } else {
      l[i] = r;
    }
    state.setKeyActions(l);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(backgroundColor: t.bg, foregroundColor: t.text, title: Text('按键', style: TextStyle(color: t.text))),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
          ..._actions(context, t),
          const SizedBox(height: 24),
          _LayoutEditor(state: state),
          QuickSyncLine(state: state),
        ]),
      ),
    );
  }

  List<Widget> _actions(BuildContext context, RappTokens t) {
    final l = state.quick.keys;
    final stars = state.quick.stars;
    return [
      Text('按键动作', style: TextStyle(color: t.muted)),
      const SizedBox(height: 8),
      ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorderItem: (from, to) {
          final m = List.of(l);
          m.insert(to, m.removeAt(from));
          state.setKeyActions(m);
        },
        children: [
          for (final (i, a) in l.indexed)
            Dismissible(
              key: ValueKey('keys-dismiss-${a.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                color: Colors.red.withValues(alpha: .7),
                child: const Text('删除', style: TextStyle(color: Colors.white)),
              ),
              // Deleting also drops the star and any layout cell (QuickPrefs.setKeys).
              onDismissed: (_) => state.setKeyActions([for (final k in state.quick.keys) if (k.id != a.id) k]),
              child: ListTile(
                key: Key('keys-row-${a.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text('${a.label}  ${a.chord.label}',
                    style: TextStyle(color: t.text), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: a.per.isEmpty
                    ? null
                    : Text(_perSubtitle(a), style: TextStyle(color: t.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => _edit(context, i),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    key: Key('keys-star-${a.id}'),
                    tooltip: stars.contains(a.ref) ? '取消打星' : '打星',
                    icon: Icon(stars.contains(a.ref) ? Icons.star : Icons.star_border,
                        color: stars.contains(a.ref) ? t.text : t.muted),
                    onPressed: () => state.toggleStar(a.ref),
                  ),
                  ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle, color: t.muted)),
                ]),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        RappButton.secondary(key: const Key('keys-add'), label: '＋ 新增按键动作', onPressed: () => _edit(context, null)),
        // The plain built-ins; a search action migrated from the old 常用语条 loses its per-tool table too.
        RappButton.quiet(
            key: const Key('keys-restore-actions'),
            label: '恢复默认按键动作',
            onPressed: () => state.setKeyActions(builtinKeyActions)),
      ]),
      const SizedBox(height: 8),
      Text('打了星的按键动作出现在第一行；删掉一个按键动作，它的星和键盘里的格子也一起去掉。', style: TextStyle(color: t.muted)),
    ];
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

  MainState get _s => widget.state;

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
    setState(() => _sel = null);
  }

  String _faceOf(String id) {
    if (id.startsWith('k:')) {
      for (final a in _s.quick.keys) {
        if (a.ref == id) return a.label;
      }
      return id;
    }
    return barKeys[id]?.label ?? id;
  }

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
    // A change from elsewhere (another device's layout) can leave the selection pointing past the row.
    final sel = _sel;
    if (sel != null && sel.$2 >= rows[sel.$1].length) _sel = null;
    final candidates = [
      for (final id in barKeys.keys)
        if (id != 'more') id,
      for (final a in _s.quick.keys) a.ref,
    ];
    final target = _sel != null ? '点下面的键换掉这一格' : _adding != null ? '点下面的键加到第 ${_adding! + 1} 行末尾' : '先点一格或行末的＋';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('键盘布局', style: TextStyle(color: t.muted)),
      const SizedBox(height: 8),
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
            key: const Key('keys-restore-layout'), label: '恢复默认布局', onPressed: () => _s.setKeyLayout(KeyLayout.fallback)),
      ),
    ]);
  }
}
