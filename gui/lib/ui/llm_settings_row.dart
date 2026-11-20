// 全局设置 → LLM 接入点: the gateway's address and key (`local/llm.json`), and 测试 to see whether it answers.
import 'dart:async';

import 'package:flutter/material.dart';

import '../llm_api.dart';
import 'controls.dart';
import 'main_state.dart';
import 'secure_text_field.dart';
import 'tokens.dart';

class LlmSettingsRow extends StatefulWidget {
  const LlmSettingsRow({super.key, required this.state, required this.style});

  final MainState state;
  final TextStyle style;

  @override
  State<LlmSettingsRow> createState() => _LlmSettingsRowState();
}

class _LlmSettingsRowState extends State<LlmSettingsRow> {
  late final _url = TextEditingController(text: widget.state.llm.url);
  late final _key = TextEditingController(text: widget.state.llm.key);
  final _urlFocus = FocusNode(debugLabel: 'llm-url');
  final _keyFocus = FocusNode(debugLabel: 'llm-key');
  bool _testing = false;
  LlmProbe? _probe;
  // The probe belongs to this endpoint; editing either field clears it.
  LlmEndpoint? _probed;
  // A field was edited since the last save: only then does folding away write back.
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _urlFocus.addListener(() => _saveOnBlur(_urlFocus));
    _keyFocus.addListener(() => _saveOnBlur(_keyFocus));
  }

  @override
  void dispose() {
    // Folded away or the panel closed with an edit still in a field: save it, after the tree is unlocked
    // ([MainState.setLlm] notifies).
    if (_dirty) {
      final typed = _typed, state = widget.state;
      scheduleMicrotask(() => state.setLlm(typed));
    }
    _url.dispose();
    _key.dispose();
    _urlFocus.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  LlmEndpoint get _typed => LlmEndpoint(url: _url.text.trim(), key: _key.text.trim());

  void _saveOnBlur(FocusNode n) {
    if (!n.hasFocus) _commit();
  }

  void _commit() {
    _dirty = false;
    widget.state.setLlm(_typed);
  }

  void _edited(String _) {
    _dirty = true;
    if (_probed != null && _probed != _typed) setState(() => _probe = _probed = null);
  }

  Future<void> _test() async {
    _commit();
    final e = _typed;
    setState(() {
      _testing = true;
      _probe = null;
    });
    final p = await widget.state.llmApi.probe(e);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _probe = p;
      _probed = e;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = widget.style;
    InputDecoration deco(String hint) => InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: style.copyWith(color: t.muted),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        );
    final p = _probe;
    final status = _testing ? '测试中…' : p?.line;
    return Padding(
      key: const Key('llm-settings'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('LLM 接入点', style: style)),
          RappButton.secondary(key: const Key('llm-test'), label: '测试', onPressed: _testing ? null : _test),
        ]),
        const SizedBox(height: 4),
        TextField(
          key: const Key('llm-url'),
          controller: _url,
          focusNode: _urlFocus,
          style: style,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          decoration: deco(llmUrlHint),
          onChanged: _edited,
          onSubmitted: (_) => _commit(),
        ),
        const SizedBox(height: 4),
        SecureTextField(
          key: const Key('llm-key'),
          controller: _key,
          focusNode: _keyFocus,
          decoration: deco('key'),
          onChanged: _edited,
          onSubmitted: (_) => _test(),
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              status,
              key: const Key('llm-status'),
              style: style.copyWith(
                color: _testing || p!.ok ? t.muted : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ]),
    );
  }
}
