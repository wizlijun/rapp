// 全局设置 → 语音学到的词: what the gateway was taught by corrections, one line each, with a delete.
// Folded at first; it asks the gateway only when opened, and the whole row goes when the gateway cannot answer.
import 'package:flutter/material.dart';

import '../llm_api.dart';
import 'main_state.dart';
import 'side_panel.dart' show settingsRowHeight;
import 'tokens.dart';

class VoiceLearnedRow extends StatefulWidget {
  const VoiceLearnedRow({super.key, required this.state, required this.style});

  final MainState state;
  final TextStyle style;

  @override
  State<VoiceLearnedRow> createState() => _VoiceLearnedRowState();
}

class _VoiceLearnedRowState extends State<VoiceLearnedRow> {
  bool _open = false;
  bool _loading = false;
  bool _gone = false;
  List<LearnedEntry>? _entries;

  Future<void> _toggle() async {
    if (_open) {
      setState(() => _open = false);
      return;
    }
    setState(() {
      _open = true;
      _loading = true;
    });
    final got = await widget.state.voiceLearned();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _entries = got;
      _gone = got == null;
    });
  }

  Future<void> _forget(String id) async {
    setState(() => _entries = [for (final e in _entries ?? const <LearnedEntry>[]) if (e.id != id) e]);
    await widget.state.forgetLearned(id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        if (!widget.state.llm.configured || _gone) return const SizedBox.shrink();
        final t = RappTokens.of(context);
        final small = widget.style;
        final entries = _entries;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            key: const Key('voice-learned'),
            borderRadius: BorderRadius.circular(t.r),
            onTap: _toggle,
            child: SizedBox(
              height: settingsRowHeight(Theme.of(context).platform),
              child: Row(children: [
                Expanded(child: Text('语音学到的词', style: small)),
                Icon(_open ? Icons.expand_more : Icons.chevron_right, color: t.muted, size: 18),
              ]),
            ),
          ),
          if (_open && _loading) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('…', style: small.copyWith(color: t.muted))),
          if (_open && !_loading && entries != null && entries.isEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('还没有', style: small.copyWith(color: t.muted))),
          if (_open && entries != null)
            for (final e in entries)
              SizedBox(
                key: Key('voice-learned-${e.id}'),
                height: settingsRowHeight(Theme.of(context).platform),
                child: Row(children: [
                  Expanded(child: Text(e.label, style: small, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  InkWell(
                    key: Key('voice-learned-delete-${e.id}'),
                    borderRadius: BorderRadius.circular(t.r),
                    onTap: () => _forget(e.id),
                    child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.close, color: t.muted, size: 16)),
                  ),
                ]),
              ),
        ]);
      },
    );
  }
}
