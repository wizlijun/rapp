// 访问记录 (observability spec §6): one `history` event as a display row.

/// Path words shared with the 日志 screen.
const pathWords = {'lan': '局域网', 'direct': '直连', 'relay': '中继'};

class HistoryRow {
  const HistoryRow({
    required this.time,
    required this.who,
    required this.path,
    required this.app,
    required this.duration,
    required this.result,
    required this.warn,
  });

  /// Local time, `MM-dd HH:mm:ss`.
  final String time;

  /// `name（自称）· addr`, or just the address when B sent no name.
  final String who;
  final String path;
  final String app;
  final String duration;
  final String result;

  /// Refused (auth_fail, rejected, failed request): shown in the warning colour.
  final bool warn;
}

HistoryRow historyRow(Map<String, dynamic> ev) {
  String s(String k) => ev[k] is String ? ev[k] as String : '';
  final peer = s('peer'), name = s('name');
  final (result, warn) = switch (s('ev')) {
    'session_start' => ('开始', false),
    'session_end' => (s('reason') == 'taken over' ? (s('by').isEmpty ? '被另一台设备接管' : '被 ${s('by')} 接管') : _endReason(s('reason')), false),
    'input_blocked' => ('输入被挡：${s('by').isEmpty ? '另一台设备' : s('by')} 正在操作', false),
    'auth_fail' => ('拒绝：${s('reason')}', true),
    'request' => ('失败：${s('result')}', true),
    // The host turned the session away (busy, version mismatch, bad token).
    'rejected' => ('拒绝：${s('reason')}', true),
    'unlock' => ('输入了系统密码', false),
    'auto_lock' => ('远程 app 都已关闭，已自动锁屏', false),
    'auto_lock_failed' => ('自动锁屏失败：${s('error')}', true),
    final other => (other, false),
  };
  return HistoryRow(
    time: _localTime(s('ts')),
    who: name.isEmpty ? peer : '$name（自称）· $peer',
    path: pathWords[s('path')] ?? s('path'),
    app: s('op') == 'list_apps' ? '（列出应用）' : _appWord(s('app')),
    duration: ev['secs'] is int ? _duration(ev['secs'] as int) : '',
    result: result,
    warn: warn,
  );
}

String _appWord(String app) => app == 'desktop:'
    ? '桌面'
    : app.startsWith('desktop:')
        ? '桌面（其他屏）'
        : app;

String _endReason(String reason) => switch (reason) {
      'closed' => '结束',
      'kicked' => '被断开',
      _ => '中断：$reason',
    };

String _two(int n) => n.toString().padLeft(2, '0');

String _localTime(String ts) {
  final t = DateTime.tryParse(ts)?.toLocal();
  if (t == null) return '';
  return '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

String _duration(int secs) {
  if (secs < 60) return '$secs秒';
  if (secs < 3600) return '${secs ~/ 60}分${_two(secs % 60)}秒';
  return '${secs ~/ 3600}时${_two(secs % 3600 ~/ 60)}分';
}
