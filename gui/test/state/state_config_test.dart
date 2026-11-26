import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/state/state_config.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('state_cfg'));
  tearDown(() => dir.deleteSync(recursive: true));

  void put(String s) => File('${dir.path}/state.json').writeAsStringSync(s);

  test('missing file is auto', () => expect(StateConfig.load(dir.path).mode, StateMode.auto));

  test('manual round trips', () {
    const StateConfig(StateMode.manual, url: 'http://x:1').save(dir.path);
    final c = StateConfig.load(dir.path);
    expect(c.mode, StateMode.manual);
    expect(c.url, 'http://x:1');
    const StateConfig(StateMode.off).save(dir.path);
    expect(StateConfig.load(dir.path).mode, StateMode.off);
  });

  test('bad json and unknown mode are auto', () {
    put('{nope');
    expect(StateConfig.load(dir.path).mode, StateMode.auto);
    put('{"mode":"weird"}');
    expect(StateConfig.load(dir.path).mode, StateMode.auto);
    put('[1]');
    expect(StateConfig.load(dir.path).mode, StateMode.auto);
  });

  test('checkUrl', () {
    expect(StateConfig.checkUrl('ftp://x'), '地址要以 http:// 或 https:// 开头');
    expect(StateConfig.checkUrl('x:1'), isNotNull);
    expect(StateConfig.checkUrl('http://localhost:8102'), isNull);
    expect(StateConfig.checkUrl('https://a.b'), isNull);
  });

  test('saved file is 0600', () {
    const StateConfig(StateMode.off).save(dir.path);
    expect((FileStat.statSync('${dir.path}/state.json').mode & 0x1ff).toRadixString(8), '600');
  }, skip: Platform.isWindows);
}
