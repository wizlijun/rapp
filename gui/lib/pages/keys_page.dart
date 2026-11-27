// 按键 settings (quick-row spec §6.4): the 按键动作 list (drag to reorder, swipe to delete, tap to edit, ★ to put on the
// first row), 新增 and 恢复默认按键动作; and the sheet that edits one action. The key layout section comes below.
import 'package:flutter/material.dart';

import '../embed/key_bar_keys.dart';
import '../embed/strip_tools.dart';
import '../quick/key_actions.dart';
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
          // The key layout section (spec §6.4) goes here.
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
