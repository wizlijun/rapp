// 数据目录: where rapp keeps its data, whether git is tracking it, and a way to open it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

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
  const DataSection({super.key, required this.data, this.openFolder = openFolderDefault});
  final DataDir data;
  final Future<void> Function(String path) openFolder;

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
        Wrap(spacing: 8, children: [OutlinedButton(onPressed: _open, child: const Text('打开数据目录'))]),
      ]);
}
