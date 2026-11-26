// 设置里的“状态服务”：这台设备怎么找 rapp-state（自动 / 关 / 手填地址），以及现在连得怎么样。
import 'package:flutter/material.dart';

import '../state/state_config.dart';
import '../state/state_sync.dart';
import 'section_card.dart';

class StateSection extends StatefulWidget {
  const StateSection({super.key, required this.sync});

  final StateSync sync;

  @override
  State<StateSection> createState() => _StateSectionState();
}

class _StateSectionState extends State<StateSection> {
  late final _url = TextEditingController(text: widget.sync.config.url);
  // Leaving the field saves it as Enter does (unless it is what is saved already).
  late final _focus = FocusNode()..addListener(_onFocus);
  String? _hint;
  // Picking 手填地址 shows the field before an address is saved.
  bool _manual = false;

  StateSync get _sync => widget.sync;

  @override
  void dispose() {
    _focus.dispose();
    _url.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus || !mounted) return;
    final v = _url.text.trim();
    final c = _sync.config;
    if (v.isEmpty || (c.mode == StateMode.manual && c.url == v)) return;
    _submit(v);
  }

  String _status() => switch (_sync.status) {
    StateStatus.connected => '已连上 ${_sync.url ?? ''}',
    StateStatus.unreachable => '连不上',
    StateStatus.none => '没找到状态服务',
    StateStatus.off => '已关',
    StateStatus.connecting => '连接中…',
  };

  void _pick(StateMode m) {
    setState(() {
      _manual = m == StateMode.manual;
      _hint = null;
    });
    if (m != StateMode.manual) _sync.setConfig(StateConfig(m));
  }

  void _submit(String v) {
    final bad = StateConfig.checkUrl(v);
    setState(() => _hint = bad);
    if (bad == null) _sync.setConfig(StateConfig(StateMode.manual, url: v.trim()));
  }

  Widget _choice(String label, StateMode m, StateMode current) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(m == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
    title: Text(label),
    onTap: () => _pick(m),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _sync,
    builder: (context, _) {
      final mode = _manual ? StateMode.manual : _sync.config.mode;
      return SectionCard(title: '状态服务', children: [
        _choice('自动', StateMode.auto, mode),
        _choice('关', StateMode.off, mode),
        _choice('手填地址', StateMode.manual, mode),
        if (mode == StateMode.manual)
          TextField(
            controller: _url,
            focusNode: _focus,
            decoration: InputDecoration(isDense: true, hintText: 'http://', errorText: _hint),
            onSubmitted: _submit,
          ),
        const SizedBox(height: 4),
        Text(_status(), style: Theme.of(context).textTheme.bodySmall),
      ]);
    },
  );
}
