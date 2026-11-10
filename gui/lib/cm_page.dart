// `rapp --cm`: the connection-manager window on the A side (spec §4).
import 'dart:async';

import 'package:flutter/material.dart';

import 'service_client.dart';

/// Fires [onQuit] once the session count has been zero for [delay].
/// Unknown counts (no status yet) never arm it.
class CmAutoQuit {
  CmAutoQuit({required this.onQuit, this.delay = const Duration(seconds: 5)});
  final VoidCallback onQuit;
  final Duration delay;
  Timer? _timer;

  void update(int sessions) {
    if (sessions > 0) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer(delay, onQuit);
    }
  }

  void dispose() => _timer?.cancel();
}

class CmPage extends StatefulWidget {
  const CmPage({super.key, required this.monitor, required this.onQuit});
  final ServiceMonitor monitor;
  final VoidCallback onQuit;

  @override
  State<CmPage> createState() => _CmPageState();
}

class _CmPageState extends State<CmPage> {
  late final CmAutoQuit _quit = CmAutoQuit(onQuit: widget.onQuit);
  var _everConnected = false;

  @override
  void initState() {
    super.initState();
    widget.monitor.addListener(_onChange);
  }

  void _onChange() {
    final st = widget.monitor.status;
    if (st != null) {
      _everConnected = true;
      _quit.update(st.sessions.length);
    } else if (_everConnected) {
      _quit.update(0); // service went away: its sessions are gone
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.monitor.removeListener(_onChange);
    _quit.dispose();
    super.dispose();
  }

  Future<void> _kick(Object sid) async {
    try {
      await widget.monitor.kick(sid);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('断开失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.monitor.status;
    final sessions = st?.sessions ?? const <ServiceSession>[];
    return Scaffold(
      appBar: AppBar(title: const Text('rapp 连接管理'), toolbarHeight: 44),
      body: st == null
          ? Center(child: Text('服务未运行（${widget.monitor.error ?? 'connecting'}）'))
          : sessions.isEmpty
              ? const Center(child: Text('没有会话，5 秒后关闭'))
              : ListView(
                  children: [
                    for (final s in sessions)
                      ListTile(
                        key: Key('cm-${s.sid}'),
                        dense: true,
                        leading: const Icon(Icons.desktop_windows_outlined),
                        title: Text(s.app),
                        subtitle: Text('${s.peer} · ${s.path}'),
                        trailing: FilledButton.tonal(onPressed: () => _kick(s.sid), child: const Text('断开')),
                      ),
                  ],
                ),
    );
  }
}
