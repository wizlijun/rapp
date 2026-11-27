// 全局设置 → 命令 (cmd-menu design): the commands of the 常用语 doc (drag to reorder, swipe to delete, tap to edit per tool),
// 新增 and 恢复默认; and the sheet that edits one command (strip-commands spec).
import 'package:flutter/material.dart';

import '../embed/key_bar_keys.dart';
import '../embed/strip_cmds.dart';
import '../embed/strip_tools.dart';
import '../quick/quick_prefs.dart';
import 'quick_sync_line.dart';
import 'strip_kind_list.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';

Future<void> openCmdsPage(BuildContext context, MainState state) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CmdsPage(state: state)));

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

class CmdsPage extends StatelessWidget {
  const CmdsPage({super.key, required this.state});
  final MainState state;

  Future<void> _edit(BuildContext context, int? i) async {
    final l = itemsOf<StripCmd>(state);
    final r = await editStripCmd(context, c: i == null ? null : l[i]);
    if (r == null) return;
    if (i == null) {
      l.add(r);
    } else {
      l[i] = r;
    }
    setItemsOf<StripCmd>(state, l);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(backgroundColor: t.bg, foregroundColor: t.text, title: Text('命令', style: TextStyle(color: t.text))),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
          StripKindList<StripCmd>(
            state: state,
            rowKey: 'cmd-row-',
            starKey: 'cmds-star-',
            title: (c, t) => Text(c.labelOf(), style: TextStyle(color: t.text), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: (c, t) =>
                Text(_cmdSubtitle(c), style: TextStyle(color: t.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
            onEdit: (i) => _edit(context, i),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            RappButton.secondary(key: const Key('cmd-add'), label: '＋ 新增命令', onPressed: () => _edit(context, null)),
            // The built-in commands as shipped; the phrases stay as they are.
            RappButton.quiet(
                key: const Key('cmd-reset'),
                label: '恢复默认',
                onPressed: () => setItemsOf<StripCmd>(state, defaultQuickPhrases.whereType<StripCmd>().toList())),
          ]),
          const SizedBox(height: 16),
          Text('命令只在文字终端里认出 Claude Code、Codex 等工具时出现。', style: TextStyle(color: t.muted)),
          QuickSyncLine(state: state),
        ]),
      ),
    );
  }
}
