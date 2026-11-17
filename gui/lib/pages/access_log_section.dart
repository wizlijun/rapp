// 访问记录: who reached this machine, newest first (observability spec §6).
import 'package:flutter/material.dart';

import '../access_log.dart';
import 'section_card.dart';

class AccessLogSection extends StatefulWidget {
  const AccessLogSection({
    super.key,
    required this.load,
    required this.logDir,
    required this.openFolder,
    this.reload,
    this.limit,
    this.onMore,
  });

  /// The service's `history` events, newest first.
  final Future<List<Map<String, dynamic>>> Function() load;

  /// Null while the service has not said where its log is.
  final String? logDir;
  final Future<void> Function(String dir) openFolder;

  /// Fires when the rows may have changed (the service's `changed` events).
  final Listenable? reload;

  /// Show only the newest this many (still live); null shows them all.
  final int? limit;

  /// 更多: the whole record elsewhere (the log screen). No button when null.
  final VoidCallback? onMore;

  @override
  State<AccessLogSection> createState() => _AccessLogSectionState();
}

class _AccessLogSectionState extends State<AccessLogSection> {
  List<HistoryRow>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.reload?.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.reload?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final events = await widget.load();
      if (!mounted) return;
      setState(() {
        _rows = events.map(historyRow).toList();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dir = widget.logDir;
    final warn = Theme.of(context).colorScheme.error;
    final rows = _rows;
    return SectionCard(
      title: '访问记录',
      action: IconButton(tooltip: '刷新', icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
      children: [
        if (_error != null)
          Text('读取失败：$_error', style: TextStyle(color: warn))
        else if (rows == null)
          const Text('读取中…')
        else if (rows.isEmpty)
          const Text('（还没有记录）')
        else
          for (final r in widget.limit == null ? rows : rows.take(widget.limit!)) _row(r, warn),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (widget.onMore != null)
            OutlinedButton(key: const Key('access-log-more'), onPressed: widget.onMore, child: const Text('更多')),
          OutlinedButton(
            onPressed: dir == null ? null : () => widget.openFolder(dir),
            child: const Text('打开日志文件夹'),
          ),
        ]),
      ],
    );
  }

  Widget _row(HistoryRow r, Color warn) {
    final style = r.warn ? TextStyle(color: warn) : null;
    final detail = [r.path, r.app, r.duration, r.result].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(r.time, style: const TextStyle(color: Colors.grey))),
        Expanded(child: SelectableText(r.who)),
        Expanded(child: Text(detail, style: style)),
      ]),
    );
  }
}
