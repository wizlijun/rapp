// The main window: 本机 / 主机 / 会话, with a banner when rapp-hub is missing.
import 'package:flutter/material.dart';

import 'hub_client.dart';
import 'pages/hosts_section.dart';
import 'pages/local_section.dart';
import 'pages/section_card.dart';
import 'pages/sessions_section.dart';
import 'service_client.dart';
import 'service_control.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.hub,
    required this.hubError,
    required this.monitor,
    required this.control,
    required this.configDir,
  });

  final HubClient? hub;
  final String? hubError;
  final ServiceMonitor monitor;
  final ServiceController? control;
  final String configDir;

  @override
  Widget build(BuildContext context) {
    final h = hub;
    final local = LocalSection(monitor: monitor, control: control, configDir: configDir);
    final Widget hosts, sessions;
    if (h == null) {
      const off = [Padding(padding: EdgeInsets.all(8), child: Text('rapp-hub 不可用'))];
      hosts = const SectionCard(title: '主机', children: off);
      sessions = const SectionCard(title: '会话', children: off);
    } else {
      hosts = HostsSection(hub: h);
      sessions = SessionsSection(hub: h);
    }

    return Scaffold(
      body: Column(children: [
        _Banner(hub: h, startError: hubError),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 760
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: SingleChildScrollView(child: Column(children: [local, sessions]))),
                    Expanded(child: SingleChildScrollView(child: hosts)),
                  ])
                : SingleChildScrollView(child: Column(children: [local, hosts, sessions])),
          ),
        ),
      ]),
    );
  }
}

/// Red strip for "rapp-hub not found / exited", plus unsolicited hub errors.
class _Banner extends StatelessWidget {
  const _Banner({required this.hub, required this.startError});
  final HubClient? hub;
  final String? startError;

  @override
  Widget build(BuildContext context) {
    final h = hub;
    if (h == null) return _strip(context, startError ?? 'rapp-hub not found');
    return ListenableBuilder(
      listenable: h,
      builder: (context, _) {
        final msg = !h.alive ? 'rapp-hub exited — 重启 rapp 以恢复' : h.lastError;
        return msg == null ? const SizedBox.shrink() : _strip(context, msg);
      },
    );
  }

  Widget _strip(BuildContext context, String msg) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Icon(Icons.error_outline, color: cs.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(child: SelectableText(msg, style: TextStyle(color: cs.onErrorContainer))),
        ]),
      ),
    );
  }
}
