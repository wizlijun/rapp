// 全局设置 on iOS, under 实体键盘用内置输入法 while it is on: the 词库 choice, 重新部署 and the engine's status.
import 'package:flutter/material.dart';
import 'package:rapp_rime/rapp_rime.dart';

import '../embed/rime_glue.dart';
import '../ui/controls.dart';
import '../ui/tokens.dart';

const rimeFolderHint = '把 Rime 目录放进「文件」→ rapp → Rime 后可选';

class RimeSettingsSection extends StatelessWidget {
  const RimeSettingsSection({super.key, required this.glue});

  final RimeGlue glue;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: glue.state,
        builder: (context, _) => glue.enabled ? _RimeRows(glue: glue) : const SizedBox.shrink(),
      );
}

class _RimeRows extends StatefulWidget {
  const _RimeRows({required this.glue});

  final RimeGlue glue;

  @override
  State<_RimeRows> createState() => _RimeRowsState();
}

class _RimeRowsState extends State<_RimeRows> with WidgetsBindingObserver {
  bool _folderReady = false;

  RimeGlue get _glue => widget.glue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFolder();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the Files app (where the Rime folder is added): ask again whether it is there.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadFolder();
  }

  Future<void> _loadFolder() async {
    final f = await _glue.userFolder();
    if (mounted) setState(() => _folderReady = f.ready);
  }

  static String _statusText(RimeStatus s) => switch (s.state) {
        RimeState.off => '',
        RimeState.starting => '部署中…',
        RimeState.ready => '就绪',
        RimeState.error => '出错：${s.message}',
      };

  @override
  Widget build(BuildContext context) {
    final user = _glue.dictionary == RimeDictionary.user;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(key: const Key('rime-dictionary'), mainAxisSize: MainAxisSize.min, children: [
        RappChoice(label: '自带雾凇', selected: !user, onTap: () => _glue.setDictionary(RimeDictionary.bundled)),
        const SizedBox(width: 16),
        RappChoice(
          label: '我的目录',
          selected: user,
          dim: !_folderReady,
          onTap: _folderReady ? () => _glue.setDictionary(RimeDictionary.user) : null,
        ),
      ]),
      if (!_folderReady)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(rimeFolderHint, style: TextStyle(color: RappTokens.of(context).muted, fontSize: 12)),
        ),
      Row(children: [
        RappButton.secondary(
          key: const Key('rime-redeploy'),
          label: '重新部署',
          onPressed: () {
            _glue.redeploy();
            _loadFolder();
          },
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ListenableBuilder(
            listenable: _glue.rime,
            builder: (context, _) => Text(_statusText(_glue.rime.status), key: const Key('rime-status')),
          ),
        ),
      ]),
    ]);
  }
}
