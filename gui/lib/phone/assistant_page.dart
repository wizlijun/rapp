/// The 助理 page: what the user said to it, kept on this phone (V1c Task 16, V8, V10). It does not answer yet, and
/// nothing on it goes to a terminal.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/tokens.dart';
import 'assistant_store.dart';
import 'phone_nav.dart';
import 'widgets.dart';

class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key, required this.store, required this.nav});
  final AssistantStore store;
  final PhoneNav nav;

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final _input = TextEditingController();
  Timer? _copiedTimer;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    // 「编辑」 from the home: the words wait in the input until 存下.
    final d = widget.nav.assistantDraft;
    widget.nav.assistantDraft = null;
    if (d != null) _input.text = d;
    _input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _save() {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    widget.store.add(t);
    _input.clear();
  }

  static String _when(int at) {
    final d = DateTime.fromMillisecondsSinceEpoch(at);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.month}月${d.day}日 ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium!;
    return PhonePage(
      title: '助理',
      onBack: widget.nav.home,
      trailing: _copied
          ? Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text('已复制', style: style.copyWith(color: t.on)),
            )
          : null,
      child: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final notes = widget.store.notes;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('助理还不会回答，先替你记着。', style: style.copyWith(color: t.muted)),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final n in notes)
                      Padding(
                        key: Key('note-${n.id}'),
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(
                            child: InkWell(
                              onLongPress: () => _copy(n.text),
                              child: Container(
                                constraints: const BoxConstraints(minHeight: phoneTap),
                                alignment: Alignment.centerLeft,
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(n.text, style: style.copyWith(color: t.text)),
                                  Text(
                                    [_when(n.at), if (n.project != null) n.project!].join(' · '),
                                    style: style.copyWith(color: t.muted),
                                  ),
                                ]),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            key: Key('note-del-${n.id}'),
                            onTap: () => widget.store.remove(n.id),
                            child: Container(
                              constraints: const BoxConstraints(minWidth: phoneTap, minHeight: phoneTap),
                              alignment: Alignment.center,
                              child: Text('删', style: style.copyWith(color: t.muted)),
                            ),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: TextField(
                      key: const Key('assistant-input'),
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      style: style.copyWith(color: t.text),
                      decoration: const InputDecoration(hintText: '写一句，记下来'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  PhoneButton(label: '存下', primary: true, onPressed: _input.text.trim().isEmpty ? null : _save),
                ]),
              ),
            ],
          );
        },
      ),
    );
  }
}
