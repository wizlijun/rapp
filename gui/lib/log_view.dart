// The 日志 screen's data: query, reply types and the Chinese wording of a row.
import 'dart:convert';

import 'access_log.dart';

enum LogKind {
  unreachable,
  refused,
  fault;

  String get wire => name;
  static LogKind? parse(Object? s) {
    for (final k in values) {
      if (k.name == s) return k;
    }
    return null;
  }
}

class LogEntry {
  LogEntry({
    required this.src,
    required this.at,
    required this.raw,
    this.kind,
    this.repeat = 0,
    this.truncated = false,
    Map<String, dynamic>? fields,
  }) : fields = fields ?? _parse(raw);

  final String src, at, raw;
  final LogKind? kind;
  final int repeat;
  final bool truncated;

  /// `jsonDecode(raw)`; empty when it does not parse.
  final Map<String, dynamic> fields;

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        src: '${j['src'] ?? ''}',
        at: '${j['at'] ?? ''}',
        raw: '${j['raw'] ?? ''}',
        kind: LogKind.parse(j['kind']),
        repeat: j['repeat'] is int ? j['repeat'] as int : 0,
        truncated: j['truncated'] == true,
      );

  static Map<String, dynamic> _parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    return const {};
  }
}

class LogPage {
  const LogPage({
    required this.events,
    required this.more,
    this.gap = false,
    this.older,
    this.newer,
    this.counts,
    this.latest,
    this.launchd,
  });

  final List<LogEntry> events;
  final bool more;

  /// An `after` poll was cut short: refresh in full.
  final bool gap;
  final String? older, newer;
  final Map<LogKind, int>? counts;
  final Map<LogKind, LogEntry>? latest;
  final List<String>? launchd;

  factory LogPage.fromJson(Map<String, dynamic> j) {
    Map<LogKind, T>? byKind<T>(Object? m, T? Function(Object?) f) {
      if (m is! Map) return null;
      return {
        for (final k in LogKind.values)
          k: ?f(m[k.wire]),
      };
    }

    return LogPage(
      events: [for (final e in j['events'] as List? ?? const []) if (e is Map) LogEntry.fromJson(Map<String, dynamic>.from(e))],
      more: j['more'] == true,
      gap: j['gap'] == true,
      older: j['older'] as String?,
      newer: j['newer'] as String?,
      counts: byKind<int>(j['counts'], (v) => v is int ? v : null),
      latest: byKind<LogEntry>(j['latest'], (v) => v is Map ? LogEntry.fromJson(Map<String, dynamic>.from(v)) : null),
      launchd: j['launchd'] is List ? [for (final l in j['launchd'] as List) '$l'] : null,
    );
  }
}

class LogQuery {
  const LogQuery({
    this.before,
    this.after,
    this.around,
    this.q,
    this.problems = false,
    this.tailLaunchd = false,
    this.kind,
    this.src,
    this.limit,
  });

  final String? before, after, around, q;
  final bool problems, tailLaunchd;
  final LogKind? kind;
  final Set<String>? src;
  final int? limit;

  Map<String, dynamic> toJson() => {
        'before': ?before,
        'after': ?after,
        'around': ?around,
        'q': ?q,
        if (problems) 'problems': true,
        if (tailLaunchd) 'tail_launchd': true,
        if (kind != null) 'kind': kind!.wire,
        if (src != null) 'src': src!.toList(),
        'limit': ?limit,
      };
}

class LogLine {
  const LogLine({required this.time, required this.summary, required this.warn, required this.fields});

  /// Local time: `HH:mm:ss` today, otherwise `MM-dd HH:mm:ss`.
  final String time, summary;
  final bool warn;
  final List<(String, String)> fields;
}

const _names = {
  'peer': '来源地址',
  'path': '路径',
  'reason': '原因',
  'sid': '会话',
  'secs': '时长',
  'id': '设备',
  'name': '名称',
  'result': '结果',
  'error': '错误',
  'msg': '消息',
};

String _two(int n) => n.toString().padLeft(2, '0');

String _time(String ts, DateTime now) {
  final t = DateTime.tryParse(ts)?.toLocal();
  if (t == null) return '';
  final hms = '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hms;
  return '${_two(t.month)}-${_two(t.day)} $hms';
}

LogLine logLine(LogEntry e, {DateTime? now, String? Function(String id)? nameOf}) {
  final f = e.fields;
  String s(String k) => f[k] == null ? '' : '${f[k]}';
  String dev() {
    final id = s('id');
    return (id.isEmpty ? null : nameOf?.call(id)) ?? id;
  }

  String join(Iterable<String> parts) => parts.where((p) => p.isNotEmpty).join(' · ');
  String head(String w, Iterable<String> rest) {
    final r = join(rest);
    return r.isEmpty ? w : '$w $r';
  }

  final ev = s('ev');
  var summary = switch (ev) {
    _ when f.isEmpty => e.raw,
    'auth_fail' || 'rejected' => head('拒绝', [s('peer'), s('reason')]),
    'map_refused' => head('端口映射被拒绝', [
        dev(),
        s('port').isEmpty ? (s('local').isEmpty ? '' : '本地 ${s('local')}') : '端口 ${s('port')}',
        s('reason'),
      ]),
    'forward_refused' => head('端口转发被拒绝', [s('peer'), s('reason')]),
    'relay_revoked' => '中继撤销了本机',
    'request' => s('result') == 'ok'
        ? head('请求', [s('peer'), s('op'), s('app')])
        : head('请求失败', [s('peer'), s('op'), s('result')]),
    'trust' => head(s('result') == 'refused' ? '信任被拒绝' : '信任', [dev().isEmpty ? s('peer') : dev(), s('reason')]),
    'route' => head('路由失败', [dev(), pathWords[s('path')] ?? s('path'), s('result').isEmpty ? s('reason') : s('result')]),
    'relay' => head('中继', [s('state') == 'error' ? '出错' : s('state'), s('error')]),
    'session_start' || 'session_end' => head('会话${ev == 'session_start' ? '开始' : '结束'}', [
        s('peer'),
        historyRow(f).result,
      ].where((x) => x != '开始')),
    'input_blocked' || 'unlock' || 'auto_lock' || 'auto_lock_failed' => historyRow(f).result,
    'term_inputs' => head('终端输入', [s('inputs').isEmpty ? '' : '${s('inputs')} 次']),
    'service_start' => '服务启动',
    'service_stop' => '服务停止',
    'update_check' => switch (s('result')) {
        'available' => head('检查更新', ['有新版本', s('latest')]),
        'up_to_date' => head('检查更新', ['已是最新', s('latest')]),
        'failed' => head('检查更新失败', [s('reason')]),
        _ => head('检查更新', [s('result'), s('reason')]),
      },
    'update_failed' => head('更新失败', [s('stage'), s('reason')]),
    'update_applied' => head('更新已安装', [s('from').isEmpty && s('to').isEmpty ? '' : '${s('from')} → ${s('to')}']),
    'presence' => '${dev().isEmpty ? s('name') : dev()} ${f['online'] == false || s('state') == 'offline' ? '离线' : '上线'}',
    'opened' => head('已打开', [s('host_name').isEmpty ? dev() : s('host_name'), s('app'), pathWords[s('path')] ?? s('path')]),
    'closed' => head('已关闭', [dev(), s('app'), s('reason')]),
    'worker_exit' => head('worker 退出', [
        s('app'),
        s('reason'),
        if (f['code'] is num && f['code'] != 0) '代码 ${f['code']}',
      ]),
    final other => join([other, s('msg')]),
  };
  if (e.repeat > 0) summary += '（又重复 ${e.repeat} 次）';

  final lvl = s('lvl');
  final warn = e.kind != null || lvl == 'warn' || lvl == 'error';
  return LogLine(
    time: _time(s('ts'), now ?? DateTime.now()),
    summary: summary,
    warn: warn,
    fields: [
      for (final k in f.keys)
        if (k != 'ts' && k != 'ev' && k != 'lvl')
          (
            _names[k] ?? k,
            switch (k) {
              'path' => pathWords[s(k)] ?? s(k),
              'secs' when f[k] is int => '${f[k]} 秒',
              _ => s(k),
            }
          ),
    ],
  );
}
