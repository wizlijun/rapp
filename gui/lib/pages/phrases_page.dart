// 全局设置 → 常用语 (iOS): the strip's switch, the list (drag to reorder, swipe to delete, tap to edit), 新增 and
// 恢复默认; and the sheet that edits one phrase (phrases spec §6).
import 'package:flutter/material.dart';

import '../embed/phrases.dart';
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
            onPressed: _ok ? () => Navigator.of(context).pop(Phrase(_text.text.trim(), put: _put)) : null,
          ),
        ]),
      ]),
    );
  }
}

class PhrasesPage extends StatelessWidget {
  const PhrasesPage({super.key, required this.state});
  final MainState state;

  List<Phrase> get _list => state.prefs.phrases;

  Future<void> _edit(BuildContext context, int? i) async {
    final p = await editPhrase(context, p: i == null ? null : _list[i]);
    if (p == null) return;
    final l = List.of(_list);
    if (i == null) {
      l.add(p);
    } else {
      l[i] = p;
    }
    state.setPhrases(l);
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
          final l = _list;
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
                state.setPhrases(m);
              },
              children: [
                for (final (i, p) in l.indexed)
                  Dismissible(
                    key: ValueKey('phrase-$i-${p.text}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 16),
                      color: Colors.red.withValues(alpha: .7),
                      child: const Text('删除', style: TextStyle(color: Colors.white)),
                    ),
                    onDismissed: (_) => state.setPhrases(List.of(l)..removeAt(i)),
                    child: ListTile(
                      key: Key('phrase-row-$i'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(p.text, style: TextStyle(color: t.text), maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: p.put ? Text('放进输入框', style: TextStyle(color: t.muted)) : null,
                      onTap: () => _edit(context, i),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: Icon(Icons.drag_handle, color: t.muted),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(children: [
              RappButton.secondary(
                  key: const Key('phrase-add'), label: '＋ 新增常用语', onPressed: () => _edit(context, null)),
              const SizedBox(width: 8),
              RappButton.quiet(
                  key: const Key('phrase-reset'),
                  label: '恢复默认',
                  onPressed: () => state.setPhrases(defaultPhrases)),
            ]),
            const SizedBox(height: 16),
            Text('常用语发出后总会按一次回车。远端停在菜单或选择框上时，回车会选中当前高亮的那一项，点之前看一眼画面。',
                style: TextStyle(color: t.muted)),
          ]);
        },
      ),
    );
  }
}
