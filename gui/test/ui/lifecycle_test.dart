import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/lifecycle.dart';

void main() {
  test('disconnect words', () {
    expect(disconnectWord('user'), '你断开了');
    expect(disconnectWord('host says: Calculator quit'), 'A 端关闭了 app');
    expect(disconnectWord('bad password'), '密码不对');
    expect(disconnectWord('offline'), '对方离线');
    expect(disconnectWord('no path to 111'), '对方离线');
    expect(disconnectWord('relay unreachable and no LAN address answered'), '对方离线');
    expect(disconnectWord('connect 10.0.0.2:21118: timed out'), '连接超时');
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
