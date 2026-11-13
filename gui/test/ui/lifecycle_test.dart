import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/lifecycle.dart';
import 'package:rapp/ui/main_state.dart' show endedHint;

void main() {
  test('disconnect words', () {
    expect(disconnectWord('user'), '你断开了');
    expect(disconnectWord('host says: Calculator quit'), 'A 端关闭了 app');
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
