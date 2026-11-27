// 全局设置 → 常用语 (iOS): the strip's switch, the list (drag to reorder, swipe to delete, tap to edit), 新增 and
// 恢复默认; and the sheet that edits one phrase (phrases spec §6).
import 'package:flutter/material.dart';

import '../embed/key_bar_keys.dart';
import '../embed/phrases.dart';
import '../embed/strip_cmds.dart';
import '../embed/strip_tools.dart';
import '../quick/quick_prefs.dart';
import 'quick_sync_line.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';

Future<void> openPhrasesPage(BuildContext context, MainState state) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => PhrasesPage(state: state)));

/// The edit sheet: [p] to change, null for a new one. Null back when cancelled.
Future<Phrase?> editPhrase(BuildContext context, {Phrase? p}) => showModalBottomSheet<Phrase>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RappTokens.of(context).bg,
      builder: (_) => _PhraseEditor(start: p),
    );

class _PhraseEditor extends StatefulWidget {
  const _PhraseEditor({this.start});
  final Phrase? start;

  @override
  State<_PhraseEditor> createState() => _PhraseEditorState();
}

class _PhraseEditorState extends State<_PhraseEditor> {
  late final _text = TextEditingController(text: widget.start?.text ?? '');
  late bool _put = widget.start?.put ?? false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _ok => _text.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.start == null ? '新增常用语' : '编辑常用语', style: TextStyle(color: t.text, fontSize: t.textSize + 2)),
        const SizedBox(height: 12),
        TextField(
          key: const Key('phrase-text'),
          controller: _text,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          style: TextStyle(color: t.text),
          decoration: const InputDecoration(hintText: '要发的话'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Text('点了之后', style: TextStyle(color: t.muted)),
        RappChoice(
            key: const Key('phrase-send'), label: '发送并回车', selected: !_put, onTap: () => setState(() => _put = false)),
        RappChoice(
            key: const Key('phrase-put'), label: '放进输入框', selected: _put, onTap: () => setState(() => _put = true)),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          RappButton.quiet(label: '取消', onPressed: () => Navigator.of(context).pop()),
          const SizedBox(width: 8),
          RappButton.primary(
            key: const Key('phrase-save'),
            label: '保存',
            onPressed: _ok ? () => Navigator.of(context).pop(Phrase(_text.text.trim(), put: _put, id: widget.start?.id)) : null,
          ),
        ]),
      ]),
    );
  }
}

/// Keys a command can send, by `barKeys` id.
const cmdPickKeys = ['cr', 'co', 'ct', 'cb', 'cl', 'stab', 'tab', 'esc', 'cc'];

/// The edit sheet for a command: [c] to change, null for a new one. Null back when cancelled.
Future<StripCmd?> editStripCmd(BuildContext context, {StripCmd? c}) => showModalBottomSheet<StripCmd>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RappTokens.of(context).bg,
      builder: (_) => _CmdEditor(start: c),
    );

class _CmdEditor extends StatefulWidget {
  const _CmdEditor({this.start});
  final StripCmd? start;

  @override
  State<_CmdEditor> createState() => _CmdEditorState();
}

class _CmdEditorState extends State<_CmdEditor> {
  late final _label = TextEditingController(text: widget.start?.labelOf() ?? '');
  late final Map<String, TextEditingController> _text = {};
  late final Map<String, String?> _key = {}; // set: this tool sends a key (maybe not picked yet)
  final Set<String> _asKey = {};

  @override
  void initState() {
    super.initState();
    for (final t in agentTools) {
      final a = widget.start == null ? null : actionFor(widget.start!, t);
      _load(t, a);
    }
  }

  void _load(AgentTool t, CmdAction? a) {
    final tc = _text.putIfAbsent(t.id, () => TextEditingController());
    tc.text = a is CmdText ? a.text : '';
    if (a is CmdKey) {
      _asKey.add(t.id);
      _key[t.id] = a.key;
    } else {
      _asKey.remove(t.id);
      _key.remove(t.id);
    }
  }

  @override
  void dispose() {
    _label.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  CmdAction? _now(AgentTool t) {
    if (_asKey.contains(t.id)) {
      final k = _key[t.id];
      return k == null ? null : CmdKey(k);
    }
    final v = _text[t.id]!.text.trim();
    return v.isEmpty ? null : CmdText(v);
  }

  bool get _ok => _label.text.trim().isNotEmpty;

  StripCmd _build() {
    final c = widget.start;
    final id = c?.id ?? 'u${DateTime.now().millisecondsSinceEpoch}';
    final b = builtinCmds[id];
    final face = _label.text.trim();
    final per = <String, CmdAction?>{};
    for (final t in agentTools) {
      final a = _now(t);
      if (b != null) {
        if (a != b.per[t.id]) per[t.id] = a;
      } else if (a != null) {
        per[t.id] = a;
      }
    }
    return StripCmd(id, label: b != null && face == b.label ? null : face, per: per);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final b = widget.start == null ? null : builtinCmds[widget.start!.id];
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.start == null ? '新增命令' : '编辑命令', style: TextStyle(color: t.text, fontSize: t.textSize + 2)),
          const SizedBox(height: 12),
          TextField(
            key: const Key('phrase-cmd-label'),
            controller: _label,
            style: TextStyle(color: t.text),
            decoration: const InputDecoration(hintText: '键面（条上显示的字）'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          for (final tool in agentTools) ...[
            Row(children: [
              SizedBox(width: 96, child: Text(tool.name, style: TextStyle(color: t.muted))),
              Expanded(
                child: _asKey.contains(tool.id)
                    ? Text(_key[tool.id] == null ? '选一个键' : barKeys[_key[tool.id]]!.label,
                        key: Key('phrase-cmd-keyshown-${tool.id}'), style: TextStyle(color: t.text))
                    : TextField(
                        key: Key('phrase-cmd-tool-${tool.id}'),
                        controller: _text[tool.id],
                        style: TextStyle(color: t.text),
                        decoration: const InputDecoration(hintText: '写法，如 /clear；留空＝没有'),
                      ),
              ),
              RappButton.quiet(
                key: Key('phrase-cmd-mode-${tool.id}'),
                label: _asKey.contains(tool.id) ? '文字' : '按键',
                onPressed: () => setState(() {
                  if (_asKey.contains(tool.id)) {
                    _asKey.remove(tool.id);
                  } else {
                    _asKey.add(tool.id);
                  }
                }),
              ),
            ]),
            if (_asKey.contains(tool.id))
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final k in cmdPickKeys)
                  ChoiceChip(
                    key: Key('phrase-cmd-key-${tool.id}-$k'),
                    label: Text(barKeys[k]!.label),
                    selected: _key[tool.id] == k,
                    onSelected: (_) => setState(() => _key[tool.id] = k),
                  ),
              ]),
            if (b != null && _now(tool) != b.per[tool.id])
              Align(
                alignment: Alignment.centerRight,
                child: RappButton.quiet(
                  key: Key('phrase-cmd-row-reset-${tool.id}'),
                  label: '恢复这一项',
                  onPressed: () => setState(() => _load(tool, b.per[tool.id])),
                ),
              ),
          ],
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            RappButton.quiet(label: '取消', onPressed: () => Navigator.of(context).pop()),
            const SizedBox(width: 8),
            RappButton.primary(
              key: const Key('phrase-cmd-save'),
              label: '保存',
              onPressed: _ok ? () => Navigator.of(context).pop(_build()) : null,
            ),
          ]),
        ]),
      ),
    );
  }
}

String _cmdSubtitle(StripCmd c) => [
      for (final t in agentTools)
        if (actionFor(c, t) case final a?)
          '${t.name} ${a is CmdText ? a.text : barKeys[(a as CmdKey).key]?.label ?? a.key}',
    ].join(' · ');

/// The row's star, the same look as the key actions page's.
class _StarButton extends StatelessWidget {
  const _StarButton({required this.index, required this.starred, required this.onPressed});
  final int index;
  final bool starred;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return IconButton(
      key: Key('phrases-star-$index'),
      tooltip: starred ? '取消打星' : '打星',
      icon: Icon(starred ? Icons.star : Icons.star_border, color: starred ? t.text : t.muted),
      onPressed: onPressed,
    );
  }
}

class PhrasesPage extends StatelessWidget {
  const PhrasesPage({super.key, required this.state});
  final MainState state;

  void _put(int? i, StripItem item) {
    final l = List.of(state.quick.phrases);
    if (i == null || i >= l.length) {
      l.add(item);
    } else {
      l[i] = item;
    }
    state.setStripItems(l);
  }

  Future<void> _edit(BuildContext context, int? i) async {
    final cur = i == null ? null : state.quick.phrases[i];
    final StripItem? r = cur is StripCmd ? await editStripCmd(context, c: cur) : await editPhrase(context, p: cur as Phrase?);
    if (r != null) _put(i, r);
  }

  Future<void> _addCmd(BuildContext context) async {
    final c = await editStripCmd(context);
    if (c != null) _put(null, c);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(backgroundColor: t.bg, foregroundColor: t.text, title: Text('常用语', style: TextStyle(color: t.text))),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final l = state.quick.phrases;
          final stars = state.quick.stars;
          return ListView(padding: const EdgeInsets.all(16), children: [
            RappSwitchRow(
              switchKey: const Key('phrase-strip-switch'),
              label: '显示常用语条',
              note: '在按键区上方；点一下就发出并回车，不动正在写的草稿',
              value: state.prefs.phraseStrip,
              onChanged: state.setPhraseStrip,
            ),
            const SizedBox(height: 8),
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) {
                final m = List.of(l);
                m.insert(to, m.removeAt(from));
                state.setStripItems(m);
              },
              children: [
                for (final (i, p) in l.indexed)
                  Dismissible(
                    key: ValueKey(p is StripCmd ? 'cmd-${p.id}' : 'phrase-$i-${(p as Phrase).text}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 16),
                      color: Colors.red.withValues(alpha: .7),
                      child: const Text('删除', style: TextStyle(color: Colors.white)),
                    ),
                    onDismissed: (_) => state.setStripItems(List.of(state.quick.phrases)..removeAt(i)),
                    child: ListTile(
                      key: Key('phrase-row-$i'),
                      contentPadding: EdgeInsets.zero,
                      title: p is StripCmd
                          ? Row(children: [
                              Container(
                                key: Key('phrase-cmd-tag-$i'),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(border: Border.all(color: t.muted), borderRadius: BorderRadius.circular(4)),
                                child: Text('命令', style: TextStyle(color: t.muted, fontSize: t.textSize - 3)),
                              ),
                              Flexible(child: Text(p.labelOf(), style: TextStyle(color: t.text), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            ])
                          : Text((p as Phrase).text, style: TextStyle(color: t.text), maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: p is StripCmd
                          ? Text(_cmdSubtitle(p), style: TextStyle(color: t.muted), maxLines: 2, overflow: TextOverflow.ellipsis)
                          : (p as Phrase).put
                              ? Text('放进输入框', style: TextStyle(color: t.muted))
                              : null,
                      onTap: () => _edit(context, i),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        _StarButton(
                          index: i,
                          starred: stars.contains(refOf(p)),
                          onPressed: () => state.toggleStar(refOf(p)),
                        ),
                        ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle, color: t.muted)),
                      ]),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              RappButton.secondary(
                  key: const Key('phrase-add'), label: '＋ 新增常用语', onPressed: () => _edit(context, null)),
              RappButton.secondary(key: const Key('phrase-cmd-add'), label: '＋ 新增命令', onPressed: () => _addCmd(context)),
              RappButton.quiet(
                  key: const Key('phrase-reset'),
                  label: '恢复默认',
                  onPressed: () => state.setStripItems(defaultQuickPhrases)),
            ]),
            const SizedBox(height: 16),
            Text('常用语发出后总会按一次回车。远端停在菜单或选择框上时，回车会选中当前高亮的那一项，点之前看一眼画面。',
                style: TextStyle(color: t.muted)),
            const SizedBox(height: 8),
            Text('命令只在文字终端里认出 Claude Code、Codex 等工具时出现。', style: TextStyle(color: t.muted)),
            QuickSyncLine(state: state),
          ]);
        },
      ),
    );
  }
}
