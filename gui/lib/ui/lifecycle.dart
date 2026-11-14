// The lifecycle of an embedded session: its record, the words for why it ended, its lamp.
import '../embed/remote_session.dart';
import '../embed/stream_choice.dart';
import 'lamp.dart';

/// Hub messages the user can meet in the hint, in plain words.
const hubWords = {
  'rapp-hub exited': 'rapp-hub 已退出',
  'unknown sid': '这个会话已经结束了',
};

String hubWord(String message) => hubWords[message] ?? message;

enum Phase { connecting, live, disconnected }

class SessionRecord {
  SessionRecord(this.id, this.app, this.appName, this.path);
  final String id;
  final String app;
  String appName;
  String path;
  Phase phase = Phase.connecting;

  /// The hub sid connected (or connecting) now.
  Object? sid;

  /// While reconnecting, the old sid whose last frame stays on show (R10).
  Object? lastSid;
  String? reason;
  int seq = 0;
  bool userDisconnect = false;

  /// Ended while reconnecting (R14).
  bool ending = false;
  StreamChoice choice = startChoice;

  /// The user picked the stream by hand: it stays pinned across reconnects.
  bool pinned = false;
  int? window;

  /// Reconnecting by itself: the failed tries so far, and when the next one is due. Null: not.
  (int attempt, DateTime at)? retry;

  /// 「停止」 was pressed while an automatic try was in flight: its result is not wanted.
  bool stopped = false;

  String get key => '$id/$app';
}

const _takenOver = 'host says: taken over';
const _takenOverBy = 'host says: taken over by ';

String _stripClient(String raw) => raw.startsWith('rapp-client: ') ? raw.substring('rapp-client: '.length) : raw;

/// The host says another device took the session over (optional `rapp-client: ` prefix).
bool takenOver(String? raw) => raw != null && _stripClient(raw).startsWith(_takenOver);

/// 「拿回来」 for a taken-over session, else 「重连」.
String reconnectLabel(String? raw) => takenOver(raw) ? '拿回来' : '重连';

/// 「这个窗口在 X 上打开了」, X the name after `taken over by `; unnamed: 「这个窗口在另一台设备上打开了」.
String _takenWords(String raw) {
  final r = _stripClient(raw);
  final name = r.startsWith(_takenOverBy) ? r.substring(_takenOverBy.length).trim() : '';
  return name.isEmpty ? '这个窗口在另一台设备上打开了' : '这个窗口在 $name 上打开了';
}

/// Plain words for why a session ended (R8); matched in order.
String disconnectWord(String? raw) {
  if (raw == null || raw.isEmpty) return hubWord('');
  if (takenOver(raw)) return _takenWords(raw);
  if (raw == 'user') return '你断开了';
  if (raw.startsWith('host says: ') && raw.endsWith('quit')) return '远端关闭了 app';
  if (raw.contains('bad password')) return '密码不对';
  if (raw.contains('relay not set')) return '没设中继，请用 ID@IP 添加';
  if (raw.contains('relay unreachable')) return '中继连不上';
  if (raw.contains('relay identity mismatch')) return '中继的身份对不上，检查接入点和 key';
  if (raw.contains('key changed')) return '中继换了 key，请到 本机 → 输入新 key';
  if (raw.contains('bad key')) return 'key 不对';
  if (raw.contains('host key mismatch')) return '对方的设备密钥变了';
  if (raw.contains('not trusted')) return '对方不认这台设备（key 不同？）';
  if (raw.contains('unknown id')) return '没有这个 ID';
  if (raw.contains('bad address')) return '接入点地址不对';
  if (raw.contains('locked, retry in')) {
    final secs = RegExp(r'locked, retry in (\d+)s').firstMatch(raw)?.group(1);
    return secs == null ? '试错太多次，稍后再试' : '试错太多次，$secs 秒后再试';
  }
  // The relay's one-word replies; `closed` (入网已关闭) is not `connection closed`.
  if (raw == 'limit' || raw.endsWith(': limit')) return '超出中继的限制，稍后再试';
  if (raw == 'closed' || raw.endsWith(': closed')) return '中继不接受新设备入网';
  if (raw.contains('offline') || raw.contains('no path to')) {
    return '对方离线';
  }
  if (raw.contains('no address')) return '没有地址，请用 ID@IP 重新添加';
  if (raw.contains('timed out') || raw.contains('no reply')) return '连接超时';
  if (raw == 'connection closed' ||
      raw == 'the host closed the connection' ||
      raw.startsWith('connection error:') ||
      raw.startsWith('connection failed:') ||
      raw.startsWith('send failed:') ||
      raw.startsWith('cannot reach ')) {
    return '网络断了';
  }
  if (raw == 'GUI did not connect') return '本机没有接上会话';
  var rest = raw;
  const client = 'rapp-client: ';
  const host = 'host says: ';
  if (rest.startsWith(client)) rest = rest.substring(client.length);
  if (rest.startsWith(host)) rest = rest.substring(host.length);
  return hubWord(rest);
}

/// The link dropped for a reason the network explains: worth trying again by itself.
bool autoReconnects(String? raw) {
  final w = disconnectWord(raw);
  return w == '网络断了' || w == '连接超时' || w == '中继连不上' || w == '对方离线';
}

/// A reason that ends automatic tries: the person, the app, the host or the password said no.
bool stopsAutoReconnect(String? raw) {
  if (raw != null && raw.contains('bad token')) return true;
  final w = disconnectWord(raw);
  return w == '你断开了' || w == '远端关闭了 app' || w == '密码不对' || takenOver(raw);
}

Lamp recordLamp(SessionRecord r, RemoteSession? rs) {
  switch (r.phase) {
    case Phase.disconnected:
      return Lamp.disconnected;
    case Phase.connecting:
      return Lamp.connecting;
    case Phase.live:
      if (rs == null || !rs.sawFrame) return Lamp.connecting;
      return rs.idle ? Lamp.idle : Lamp.active;
  }
}
