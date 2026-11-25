import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/ui/inbound.dart';

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
  const hosts = [HubHost('dev1', 'mini')];
  ServiceSession at(String peer, {String? name, bool side = false, Object? since = 1000000 - 12}) =>
      ServiceSession(1, peer, 'com.apple.Safari', 'relay', since, name: name, side: side);

  test('a terminal is titled as everywhere else; an app by its id', () {
    expect(inboundTitle('term:pty:zsh'), 'CLI · zsh');
    expect(inboundTitle('term:pty@box:zsh'), 'CLI · zsh @box');
    expect(inboundTitle('com.apple.Safari'), 'com.apple.Safari');
  });

  test('how long it has been in, rounded down', () {
    expect(inboundAge(1000000 - 12, now), '12 秒');
    expect(inboundAge(1000000 - 200, now), '3 分钟');
    expect(inboundAge(1000000 - 7300, now), '2 小时');
    expect(inboundAge(null, now), '0 秒');
    expect(inboundAge(1000000 + 50, now), '0 秒');
    expect(inboundAge('x', now), '0 秒');
  });

  test('who: a saved device name, then the declared name, then the peer', () {
    expect(inboundWho(at('dev1', name: 'iPad'), hosts), 'mini');
    expect(inboundWho(at('1.2.3.4:5', name: 'iPad'), hosts), 'iPad');
    expect(inboundWho(at('1.2.3.4:5'), hosts), '1.2.3.4:5');
    expect(inboundWho(at('1.2.3.4:5', name: ''), hosts), '1.2.3.4:5');
  });

  test('the subtitle says who and how long; a file transfer says so', () {
    expect(inboundSubtitle(at('dev1'), hosts, now), 'mini · 12 秒');
    expect(inboundSubtitle(at('dev1', side: true), hosts, now), 'mini · 12 秒 · 传文件');
  });
}
