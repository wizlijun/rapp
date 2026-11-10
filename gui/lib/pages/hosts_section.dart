// 主机: saved hosts, add/remove, per-host app list, open by bundle id.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'section_card.dart';

class HostsSection extends StatefulWidget {
  const HostsSection({super.key, required this.hub});
  final HubClient hub;

  @override
  State<HostsSection> createState() => _HostsSectionState();
}

class _HostsSectionState extends State<HostsSection> {
  final _id = TextEditingController();
  final _pw = TextEditingController();
  final _bundle = TextEditingController();
  String? _error;
  bool _busy = false;
  String? _selected;
  AppList? _apps;
  bool _loadingApps = false;

  HubClient get hub => widget.hub;

  @override
  void initState() {
    super.initState();
    hub.refreshHosts().then((_) {}, onError: (Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    _bundle.dispose();
    super.dispose();
  }

  /// Runs a hub call, turning failures into the inline error line.
  Future<void> _guard(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _add() async {
    final id = _id.text.trim(), pw = _pw.text;
    if (id.isEmpty) return;
    await _guard(() async {
      await hub.addHost(id, pw);
      _id.clear();
      _pw.clear();
    });
  }

  Future<void> _remove(String id) => _guard(() async {
        await hub.removeHost(id);
        if (_selected == id) {
          _selected = null;
          _apps = null;
        }
      });

  Future<void> _select(String id) async {
    setState(() {
      _selected = id;
      _apps = null;
      _loadingApps = true;
    });
    await _guard(() async {
      final a = await hub.apps(id);
      if (_selected == id) _apps = a;
    });
    if (mounted) setState(() => _loadingApps = false);
  }

  Future<void> _open(String app) async {
    final id = _selected;
    if (id == null || app.isEmpty) return;
    await _guard(() => hub.open(id, app));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => SectionCard(
        title: '主机',
        children: [
          for (final h in hub.hosts)
            ListTile(
              dense: true,
              selected: h.id == _selected,
              leading: const Icon(Icons.computer),
              title: Text(h.name.isEmpty ? h.id : h.name),
              subtitle: Text(h.id),
              onTap: () => _select(h.id),
              trailing: IconButton(
                key: Key('remove-${h.id}'),
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : () => _remove(h.id),
              ),
            ),
          if (hub.hosts.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('还没有主机')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('add-id'),
                controller: _id,
                decoration: const InputDecoration(labelText: 'ID 或 ID@IP（不经 relay）', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const Key('add-password'),
                controller: _pw,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码', isDense: true),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(key: const Key('add-button'), onPressed: _busy ? null : _add, child: const Text('添加')),
          ]),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (_selected != null) ..._appsPanel(context),
        ],
      ),
    );
  }

  List<Widget> _appsPanel(BuildContext context) {
    final a = _apps;
    return [
      const Divider(height: 24),
      Text(a == null ? 'App（$_selected）' : 'App（$_selected · ${a.path}）',
          style: Theme.of(context).textTheme.titleSmall),
      if (_loadingApps) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
      if (a != null && a.apps.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('对方没有可共享的窗口')),
      if (a != null)
        for (final app in a.apps)
          ListTile(
            dense: true,
            leading: const Icon(Icons.open_in_new),
            title: Text(app.name),
            subtitle: Text(app.app),
            onTap: _busy ? null : () => _open(app.app),
          ),
      Row(children: [
        Expanded(
          child: TextField(
            key: const Key('bundle-id'),
            controller: _bundle,
            decoration: const InputDecoration(labelText: 'Bundle ID，例如 com.apple.TextEdit', isDense: true),
            onSubmitted: (v) => _open(v.trim()),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          key: const Key('open-bundle'),
          onPressed: _busy ? null : () => _open(_bundle.text.trim()),
          child: const Text('打开'),
        ),
      ]),
    ];
  }
}
