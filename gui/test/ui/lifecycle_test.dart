import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart' show NetLevel;
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/lifecycle.dart';
import 'package:rapp/ui/main_state.dart' show endedHint;

void main() {
  test('offlineWords: reconnecting, waiting, retrying, stopped', () {
    final r = SessionRecord('111', 'Safari', 'Safari', 'lan')..phase = Phase.disconnected..reason = 'connection closed';
    expect(offlineWords(r), '网络断了');
    r.retry = (1, DateTime(2026));
    expect(offlineWords(r), '网络断了，正在重连…');
    expect(offlineWords(r, waiting: '对方离线，上线后自动连'), '对方离线，上线后自动连');
    r.phase = Phase.connecting;
    expect(offlineWords(r, waiting: 'x'), '正在重连…');
  });

  test('connection timeout guidance distinguishes peer UDP from relay ports', () {
    final direct = connectionFailureHint('connect 10.0.0.2:23128: timed out', peerPort: 22028);
    expect(direct, contains('UDP 23128'));
    expect(direct, contains('原因尚未确定'));
    expect(direct, contains('对方在线'));
    expect(direct, contains('ID/IP'));
    expect(direct, contains('网络隔离'));
    expect(direct, contains('防火墙'));
    expect(direct, isNot(contains('密码不对')));
    expect(direct, isNot(contains('22029')));
    final ipv6 = connectionFailureHint('connect [2001:db8::2]:24128: timed out');
    expect(ipv6, contains('UDP 24128'));
    for (final raw in ['relay unreachable: timed out', 'relay: no reply', 'timed out', 'no reply']) {
      final relay = connectionFailureHint(raw, peerPort: 22028, relayed: true);
      expect(relay, contains('中继配置的端口'));
      expect(relay, isNot(contains('UDP 22028')));
    }
    expect(connectionFailureHint('relay unreachable: timed out', peerPort: 22028), contains('中继配置的端口'));
  });

  test('connection guidance preserves other errors and does not diagnose operation timeouts', () {
    for (final raw in ['bad password', 'bad key', 'upload timed out', 'download timeout', 'command timed out']) {
      expect(connectionFailureHint(raw, peerPort: 22028), disconnectWord(raw));
    }
    final unknownPort = connectionFailureHint('no reply');
    expect(unknownPort, contains('以对方配置为准'));
    expect(unknownPort, isNot(contains('22028')));
  });

  test('disconnected stage gives connection checks without changing retry classification', () {
    final r = SessionRecord('111', 'Safari', 'Safari', 'lan')
      ..phase = Phase.disconnected
      ..reason = 'connect 10.0.0.2:23128: timed out';
    expect(offlineWords(r), contains('UDP 23128'));
    expect(autoReconnects(r.reason), true);
    r.retry = (1, DateTime.now());
    expect(offlineWords(r), endsWith('。正在重连…'));
    r.path = 'relay';
    expect(offlineWords(r), contains('中继配置的端口'));
    expect(offlineWords(r, waiting: '正在等待'), '正在等待');
  });

  test('autoReconnects', () {
    for (final raw in ['connection closed', 'send failed: x', 'timed out', 'offline', 'relay unreachable: timed out']) {
      expect(autoReconnects(raw), true, reason: raw);
    }
    for (final raw in ['user', 'host says: app quit', 'host says: taken over', 'bad password', 'bad key']) {
      expect(autoReconnects(raw), false, reason: raw);
    }
  });

  test('stopsAutoReconnect', () {
    for (final raw in ['user', 'host says: Calculator quit', 'bad password', 'bad token', 'host says: taken over by X']) {
      expect(stopsAutoReconnect(raw), true, reason: raw);
    }
    for (final raw in ['offline', 'connection closed', 'relay unreachable: timed out']) {
      expect(stopsAutoReconnect(raw), false, reason: raw);
    }
  });

  test('disconnect words', () {
    expect(disconnectWord('user'), '你断开了');
    expect(disconnectWord('host says: Calculator quit'), '远端关闭了 app');
    expect(disconnectWord('bad password'), '密码不对');
    expect(disconnectWord('offline'), '对方离线');
    expect(disconnectWord('no path to 111'), '对方离线');
    expect(disconnectWord('offline: no LAN address answered'), '对方离线');
    expect(disconnectWord('no address: add the host again as id@ip'), '没有地址，请用 ID@IP 重新添加');
    expect(disconnectWord('connect 10.0.0.2:22028: timed out'), '连接超时');
    expect(disconnectWord('no reply'), '连接超时');
    expect(disconnectWord('connection closed'), '网络断了');
    expect(disconnectWord('the host closed the connection'), '网络断了');
    expect(disconnectWord('connection error: POSIX 54'), '网络断了');
    expect(disconnectWord('cannot reach 127.0.0.1:5001 (refused)'), '网络断了');
    expect(disconnectWord('GUI did not connect'), '本机没有接上会话');
    expect(disconnectWord('cannot decode frame: bad tile'), 'cannot decode frame: bad tile');
    expect(disconnectWord('host says: window gone'), 'window gone');
    expect(disconnectWord(null), '');
  });
  test('going to the background reads 切到后台 and reconnects by itself (iPad spec §9.1)', () {
    expect(disconnectWord('background'), '切到后台');
    expect(autoReconnects('background'), true);
    expect(stopsAutoReconnect('background'), false);
  });
  test('a terminal session the device ended says so and stops automatic tries', () {
    expect(disconnectWord('session ended'), '这个会话已经结束了');
    expect(autoReconnects('session ended'), false);
    expect(stopsAutoReconnect('session ended'), true);
  });
  test('a terminal the device no longer has stops automatic tries', () {
    expect(autoReconnects('no such text terminal'), false);
    expect(stopsAutoReconnect('no such text terminal'), true);
  });
  test('relay and key words', () {
    expect(disconnectWord('relay not set: add the host as id@ip'), '没设中继，请用 ID@IP 添加');
    expect(disconnectWord('relay unreachable: connection refused'), '中继连不上');
    expect(disconnectWord('relay identity mismatch'), '中继的身份对不上，检查接入点和 key');
    expect(disconnectWord('bad key'), 'key 不对');
    expect(disconnectWord('key changed'), '中继换了 key，请到 本机 → 输入新 key');
    expect(disconnectWord('relay: key changed'), '中继换了 key，请到 本机 → 输入新 key');
    expect(disconnectWord('not trusted'), '对方不认这台设备（key 不同？）');
    expect(disconnectWord('host key mismatch'), '对方的设备密钥变了');
    expect(disconnectWord('unknown id'), '没有这个 ID');
    expect(disconnectWord('offline'), '对方离线');
    expect(disconnectWord('host says: not trusted'), '对方不认这台设备（key 不同？）');
  });
  test('relay replies in words', () {
    expect(disconnectWord('bad address'), '接入点地址不对');
    expect(disconnectWord('locked, retry in 12s'), '试错太多次，12 秒后再试');
    expect(disconnectWord('locked, retry in'), '试错太多次，稍后再试');
    expect(disconnectWord('limit'), '超出中继的限制，稍后再试');
    expect(disconnectWord('closed'), '中继不接受新设备入网');
    // Not the relay's `closed`.
    expect(disconnectWord('connection closed'), '网络断了');
    expect(disconnectWord('the host closed the connection'), '网络断了');
  });
  test('taken over words and label', () {
    expect(disconnectWord('host says: taken over by Mac mini'), '这个窗口在 Mac mini 上打开了');
    expect(disconnectWord('host says: taken over'), '这个窗口在另一台设备上打开了');
    expect(disconnectWord('rapp-client: host says: taken over by M'), '这个窗口在 M 上打开了');
    expect(reconnectLabel('host says: taken over by M'), '拿回来');
    expect(reconnectLabel('connection closed'), '重连');
    expect(endedHint('Safari', 'rapp-client: host says: taken over by M'), 'Safari：这个窗口在 M 上打开了');
    expect(endedHint('Safari', 'host says: taken over'), 'Safari：这个窗口在另一台设备上打开了');
  });
  test('waitWord: what an automatic retry waits for', () {
    final r = SessionRecord('111', 'a', 'Calculator', 'relay');
    r.reason = 'timed out';
    expect(waitWord(r, relayed: true, net: NetLevel.down), isNull, reason: 'no retry, no word');
    r.retry = (1, DateTime.now());
    expect(waitWord(r, relayed: true, net: NetLevel.down), '连不上中继，通了自动重连');
    expect(waitWord(r, relayed: true, net: NetLevel.strong), '对方网络不通，正在重试…');
    expect(waitWord(r, relayed: true, net: null), isNull, reason: 'no relay measured: nothing to tell apart');
    expect(waitWord(r, relayed: false, net: NetLevel.strong), isNull);
    r.reason = 'host offline';
    expect(waitWord(r, relayed: true, net: NetLevel.ok), '对方离线，上线后自动连');
    expect(waitWord(r, relayed: false, net: null), '对方离线，上线后自动连');
    expect(waitWord(r, relayed: true, net: NetLevel.down), '连不上中继，通了自动重连');
  });
  test('record lamps', () {
    final r = SessionRecord('111', 'a', 'Calculator', 'lan');
    expect(recordLamp(r, null), Lamp.connecting);
    r.phase = Phase.live;
    final rs = RemoteSession(1, 'Calculator');
    expect(recordLamp(r, rs), Lamp.connecting);
    rs.apply(const TrafficEvent(1, 5000, 2));
    expect(recordLamp(r, rs), Lamp.active);
    r.phase = Phase.disconnected;
    expect(recordLamp(r, rs), Lamp.disconnected);
  });
}
