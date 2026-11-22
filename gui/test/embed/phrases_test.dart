import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/ui/prefs.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rapp_phrases'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('missing file: the strip is on and the ten defaults are there', () {
    final p = UiPrefs.load(tmp.path);
    expect(p.phraseStrip, isTrue);
    expect(p.phrases.map((e) => e.text).toList(), [
      '继续', '确认', '听你的', '按你推荐的来', '进度',
      '全部做完，中途不用问我', '先出方案，别改代码', '跑一下测试', '提交并推送', '总结一下改了什么',
    ]);
  });

  test('round-trips the switch, the order and 放进输入框', () {
    UiPrefs(phraseStrip: false, phrases: const [Phrase('b', put: true), Phrase('a')]).save(tmp.path);
    final p = UiPrefs.load(tmp.path);
    expect(p.phraseStrip, isFalse);
    expect(p.phrases, const [Phrase('b', put: true), Phrase('a')]);
  });

  test('an empty list stays empty; bad entries are dropped; a non-list means the defaults', () {
    UiPrefs(phrases: const []).save(tmp.path);
    expect(UiPrefs.load(tmp.path).phrases, isEmpty);
    File('${tmp.path}/gui.json').writeAsStringSync('{"phrases":[{"text":"ok"},{"text":"  "},3,{"put":true}]}');
    expect(UiPrefs.load(tmp.path).phrases, const [Phrase('ok')]);
    File('${tmp.path}/gui.json').writeAsStringSync('{"phrases":"x","phrase_strip":"x"}');
    final p = UiPrefs.load(tmp.path);
    expect(p.phrases, defaultPhrases);
    expect(p.phraseStrip, isTrue);
  });

  test('the defaults list is not shared between prefs', () {
    final a = UiPrefs();
    a.phrases.add(const Phrase('x'));
    expect(UiPrefs().phrases, defaultPhrases);
  });
}
