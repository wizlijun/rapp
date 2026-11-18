import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../linux_firewall.dart';
import '../ui/controls.dart';

typedef FirewallCheck = Future<FirewallReport> Function({required int port,
  required List<String> localAddresses, bool authorize});

class LinuxFirewallSection extends StatefulWidget {
  const LinuxFirewallSection({super.key, required this.port, required this.localAddresses,
    this.check = checkLinuxFirewall});
  final int port;
  final List<String> localAddresses;
  final FirewallCheck check;

  @override
  State<LinuxFirewallSection> createState() => _LinuxFirewallSectionState();
}

class _LinuxFirewallSectionState extends State<LinuxFirewallSection> {
  FirewallReport? _report;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _check(false);
  }

  @override
  void didUpdateWidget(LinuxFirewallSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.port != widget.port || oldWidget.localAddresses.join(',') != widget.localAddresses.join(',')) {
      _report = null;
      _check(false);
    }
  }

  Future<void> _check(bool authorize) async {
    final generation = ++_generation;
    setState(() => _busy = true);
    FirewallReport report;
    try {
      report = await widget.check(port: widget.port, localAddresses: widget.localAddresses, authorize: authorize);
    } catch (_) {
      report = const FirewallReport();
    }
    if (!mounted || generation != _generation) return;
    setState(() { _report = report; _busy = false; });
  }

  Future<void> _showHelp() async {
    final peer = TextEditingController(text: _report?.blockedPeers.firstOrNull ?? '');
    await showDialog<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) {
      final command = ufwAllowCommand(peer.text, widget.port);
      return AlertDialog(
        title: Text('允许访问 UDP ${widget.port}'),
        content: SizedBox(width: 500, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('使用 UFW 时，在本机终端执行以下命令，仅允许指定设备访问。使用其他防火墙时，请添加对应的 UDP 入站规则。'),
            const SizedBox(height: 12),
            TextField(key: const Key('firewall-peer'), controller: peer,
              decoration: const InputDecoration(labelText: '允许访问的设备 IP'), onChanged: (_) => update(() {})),
            const SizedBox(height: 12),
            if (command != null) SelectableText(command)
            else const Text('输入对方设备的 IPv4 或 IPv6 地址后显示命令。'),
            const SizedBox(height: 12),
            const Text('修改规则后请让对方重试连接。旧拦截记录会保留一段时间；没有拦截记录也不代表网络一定畅通。'),
          ],
        ))),
        actions: [
          RappButton.quiet(label: '关闭', onPressed: () => Navigator.pop(context)),
          RappButton.quiet(label: '复制命令', onPressed: command == null ? null : () async {
            await Clipboard.setData(ClipboardData(text: command));
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制放行命令')));
          }),
        ],
      );
    }));
    peer.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final peers = report?.blockedPeers ?? const <String>[];
    final message = peers.isNotEmpty
      ? '最近 10 分钟检测到 UFW 拦截了来自 ${peers.join('、')} 的 UDP ${widget.port} 请求。请确认已允许这些设备访问，再重试连接。'
      : report?.ufwEnabled == true
        ? '检测到 UFW 已启用。请确认允许其他设备访问本机 UDP ${widget.port}；服务运行中不代表端口已放行。'
        : '局域网直连使用 UDP ${widget.port}。其他设备连接超时时，请检查本机防火墙是否允许此端口。';
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(
      key: const Key('linux-firewall'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(message),
        if (report != null && peers.isEmpty)
          Text(report.journalChecked
            ? '未找到最近的 UFW 拦截记录，这不代表端口已放行。'
            : '尚未确认拦截记录；可授权检查系统日志。'),
        Wrap(spacing: 8, children: [
          RappButton.quiet(label: _busy ? '检查中…' : '授权检查拦截记录', onPressed: _busy ? null : () => _check(true)),
          RappButton.quiet(label: '放行方法', onPressed: _showHelp),
        ]),
        const Text('检查只读取最近的 UFW 日志，可能要求管理员认证，不会修改防火墙规则。', style: TextStyle(fontSize: 12)),
      ],
    ));
  }
}
