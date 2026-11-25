import '../hub_client.dart';
import 'lamp.dart';

/// The status line of a terminal row: the program's own status when it reports one, else the quiet-time rules.
/// Whether a finished program was looked at shows in the lamp ([termLamp]), not here.
String termStatus(TermRow r, int nowSecs) {
  if (r.dead) return '已退出';
  final ps = r.ps;
  if (ps != null) return programWord(ps);
  if (r.unread) return '未读';
  final idle = nowSecs - r.activity;
  if (idle < 10) return '刚刚有输出';
  if (idle < 60) return '不到 1 分钟没动静';
  if (idle < 3600) return '${idle ~/ 60} 分钟没动静';
  return '${idle ~/ 3600} 小时没动静';
}

Lamp termLamp(TermRow r, int nowSecs) {
  if (r.dead) return Lamp.disconnected;
  switch (r.ps?.state) {
    case 'blocked':
      return Lamp.waiting;
    case 'working':
      return Lamp.active;
    case 'error':
    case 'done':
    case 'idle':
      return r.unread ? Lamp.waiting : Lamp.idle;
  }
  if (r.unread) return Lamp.waiting;
  if (nowSecs - r.activity < 10) return Lamp.active;
  return Lamp.idle;
}

/// What a program says it is doing, in words: every one of the five states (overview, rows, the status queue).
String programWord(TermPs ps) => switch (ps.state) {
      'blocked' => termAskWord(ps),
      'working' => ps.progress != null ? '在干活 · ${ps.progress}%' : '在干活',
      'error' => _msg(ps) == null ? '出错' : '出错 · ${ps.msg}',
      'done' => _msg(ps) == null ? '完成' : '完成 · ${ps.msg}',
      'idle' => '空闲',
      _ => '在干活',
    };

/// The line of a blocked program: what it waits for, then its message (plain text).
String termAskWord(TermPs ps) {
  final word = switch (ps.kind) {
    'permission' => '等确认',
    'question' => '在提问',
    'auth' => '要登录',
    _ => '在等你',
  };
  return _msg(ps) == null ? word : '$word · ${ps.msg}';
}

String? _msg(TermPs ps) => ps.msg != null && ps.msg!.isNotEmpty ? ps.msg : null;
