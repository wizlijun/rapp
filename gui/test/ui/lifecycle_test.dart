import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/lifecycle.dart';
import 'package:rapp/ui/main_state.dart' show endedHint;

void main() {
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
