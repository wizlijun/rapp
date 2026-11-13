// 数据目录: where rapp keeps its data, whether git is tracking it, and a way to open it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data_relocate.dart';
import '../paths.dart';
import 'section_card.dart';

/// R14: the words for `local/sync.json`.
String syncStatusText(Map<String, dynamic>? sync, {DateTime Function(String) parse = DateTime.parse}) {
  const none = '还没有版本记录';
  switch (sync?['git']) {
    case 'missing':
      return '没装 git，文字没有版本记录';
    case 'local':
      return '只在本机';
    case 'synced':
      final s = sync!['last_sync'];
      if (s is! String) return '已同步';
      try {
        final t = parse(s).toLocal();
        String two(int n) => n.toString().padLeft(2, '0');
        return '已同步 ${two(t.hour)}:${two(t.minute)}';
      } catch (_) {
        return '已同步';
      }
    case 'conflict':
      return '同步有冲突，需要手工处理';
    case 'error':
      return '同步没成功：${sync!['error'] ?? ''}';
    default:
      return none;
  }
}

/// `local/sync.json` as a map; null on any problem.
Map<String, dynamic>? readSyncStatus(DataDir d) {
  try {
    final v = jsonDecode(File('${d.localDir}/sync.json').readAsStringSync());
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

/// Opens [path] in the platform file manager.
Future<void> openFolderDefault(String path) async {
  final r = await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [path]);
  if (r.exitCode != 0) throw const FileSystemException('无法打开文件夹');
}

class DataSection extends StatefulWidget {
  const DataSection({
    super.key,
    required this.data,
    this.openFolder = openFolderDefault,
    this.relocate,
    this.pickFolder,
  });
  final DataDir data;
  final Future<void> Function(String path) openFolder;

  /// Null hides 更改位置…; set, it does the change.
  final DataRelocator? relocate;

  /// Asks for a folder; null uses a path dialog (no folder-picker dependency).
  final Future<String?> Function()? pickFolder;

  @override
  State<DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends State<DataSection> {
  Timer? _timer;
  Map<String, dynamic>? _sync;

  @override
  void initState() {
    super.initState();
    _sync = readSyncStatus(widget.data);
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _reread());
  }

  @override
  void didUpdateWidget(DataSection old) {
    super.didUpdateWidget(old);
    if (old.data.root != widget.data.root) _reread();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _reread() {
    if (mounted) setState(() => _sync = readSyncStatus(widget.data));
  }

  Future<void> _open() async {
    try {
      await widget.openFolder(widget.data.root);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败：$e')));
    }
  }

  void _say(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<String?> _askPath() async {
    final c = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新位置'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: '文件夹的完整路径')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('好')),
        ],
      ),
    );
    return (r == null || r.isEmpty) ? null : r;
  }

  Future<void> _move({required bool toDefault}) async {
    final r = widget.relocate!;
    final to = toDefault ? defaultDataRoot(r.env, r.os) : await (widget.pickFolder ?? _askPath)();
    if (to == null || !mounted) return;
    final from = widget.data.root;
    final plan = planRelocation(from, to);
    if (plan.error != null) return _say(plan.error!);
    final tail = '会重启服务，正在连着的会话会断一次。';
    final body = plan.kind == RelocateKind.adopt
        ? '$to 里已经有 rapp 的数据，会直接用它，$from 里的不复制过去。$tail'
        : '会把 $from 里的数据复制到 $to，原来的留着不动。$tail';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改数据目录的位置？'),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('改')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _say(await r.run(to, isDefault: toDefault));
  }

  List<Widget> _moveButtons() {
    final r = widget.relocate;
    if (r == null) return const [];
    if ((r.env['RAPP_HOME'] ?? '').isNotEmpty) return const [Text('位置由环境变量 RAPP_HOME 决定')];
    if (r.os == 'windows') return const [];
    return [
      OutlinedButton(onPressed: () => _move(toDefault: false), child: const Text('更改位置…')),
      if (widget.data.root != defaultDataRoot(r.env, r.os))
        OutlinedButton(onPressed: () => _move(toDefault: true), child: const Text('改回默认')),
    ];
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: SelectableText(value)),
        ]),
      );

  @override
  Widget build(BuildContext context) => SectionCard(title: '数据目录', children: [
        _row('位置', widget.data.root),
        _row('版本', syncStatusText(_sync)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [OutlinedButton(onPressed: _open, child: const Text('打开数据目录')), ..._moveButtons()],
        ),
      ]);
}
