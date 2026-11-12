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
  int? window;

  String get key => '$id/$app';
}

/// Plain words for why a session ended (R8); matched in order.
String disconnectWord(String? raw) {
  if (raw == null || raw.isEmpty) return hubWord('');
  if (raw == 'user') return '你断开了';
  if (raw.startsWith('host says: ') && raw.endsWith('quit')) return 'A 端关闭了 app';
  if (raw.contains('bad password')) return '密码不对';
  if (raw.contains('offline') || raw.contains('no path to') || raw.contains('relay unreachable and no LAN address answered')) {
    return '对方离线';
  }
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
