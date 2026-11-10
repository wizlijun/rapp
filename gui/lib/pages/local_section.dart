// 本机: this machine's ID/password/relay as the service sees them, plus service control.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../service_client.dart';
import '../service_control.dart';
import 'section_card.dart';

const relayLabels = {'connected': '已连接', 'connecting': '连接中', 'off': '未连接'};

class LocalSection extends StatefulWidget {
  const LocalSection({super.key, required this.monitor, required this.control, required this.configDir});
  final ServiceMonitor monitor;
  final ServiceController? control;
  final String configDir;

  @override
  State<LocalSection> createState() => _LocalSectionState();
}

class _LocalSectionState extends State<LocalSection> {
  bool _busy = false;

  ServiceMonitor get m => widget.monitor;

  void _say(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _control(ServiceAction a) async {
    final c = widget.control;
    if (c == null) return _say('找不到 rapp-service');
    setState(() => _busy = true);
    final err = await c.run(a);
    if (mounted) setState(() => _busy = false);
    _say(err ?? '已执行：${a.name}');
  }

  /// relay/key are not in `status`; prefill them from service.json if readable.
  Map<String, dynamic> _serviceJson() {
    try {
      final f = File('${widget.configDir}${Platform.pathSeparator}service.json');
      final v = jsonDecode(f.readAsStringSync());
      return v is Map<String, dynamic> ? v : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _editPassword(String current) async {
    final pw = TextEditingController(text: current);
    final ok = await _dialog('修改密码', [
      TextField(controller: pw, autofocus: true, decoration: const InputDecoration(labelText: '新密码')),
    ]);
    if (ok == true && pw.text.isNotEmpty) await _apply(() => m.setPassword(pw.text));
  }

  Future<void> _editRelay() async {
    final cfg = _serviceJson();
    final relay = TextEditingController(text: '${cfg['relay'] ?? ''}');
    final key = TextEditingController(text: '${cfg['key'] ?? ''}');
    final ok = await _dialog('Relay 设置', [
      TextField(controller: relay, autofocus: true, decoration: const InputDecoration(labelText: '地址，例如 vps:21116')),
      TextField(controller: key, decoration: const InputDecoration(labelText: 'Key')),
    ]);
    if (ok == true) await _apply(() => m.setRelay(relay.text.trim(), key.text.trim()));
  }

  Future<void> _apply(Future<void> Function() f) async {
    try {
      await f();
      _say('已保存');
    } catch (e) {
      _say('失败：$e');
    }
  }

  Future<bool?> _dialog(String title, List<Widget> fields) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: fields),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
        ),
      );

  Widget _row(String label, String value, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: SelectableText(value)),
          ?trailing,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final st = m.status;
        final buttons = Wrap(spacing: 8, children: [
          for (final (a, label) in [
            (ServiceAction.start, '启动'),
            (ServiceAction.stop, '停止'),
            (ServiceAction.restart, '重启'),
          ])
            OutlinedButton(onPressed: _busy ? null : () => _control(a), child: Text(label)),
        ]);
        return SectionCard(title: '本机', children: [
          _row('服务', st == null ? '未运行（${m.error ?? '连接中'}）' : '运行中'),
          if (st != null) ...[
            _row('ID', st.id ?? '（等待 relay 分配）'),
            _row('名称', st.name),
            _row('密码', st.password,
                trailing: IconButton(
                    tooltip: '修改密码', icon: const Icon(Icons.edit, size: 18), onPressed: () => _editPassword(st.password))),
            _row('Relay', '${relayLabels[st.relay] ?? st.relay}${st.relayError == null ? '' : '（${st.relayError}）'}',
                trailing:
                    IconButton(tooltip: '修改 relay', icon: const Icon(Icons.edit, size: 18), onPressed: _editRelay)),
            _row('权限',
                '屏幕录制 ${st.screenRecording ? '✓' : '✗'}   辅助功能 ${st.accessibility ? '✓' : '✗'}'),
            _row('会话', '${st.sessions.length} 个被访问中'),
          ],
          const SizedBox(height: 8),
          buttons,
        ]);
      },
    );
  }
}
