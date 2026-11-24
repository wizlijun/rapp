import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/voice_fix.dart';

const _v = FixSource.vocabulary, _l = FixSource.learned;

FixRule _r(String observed, String output, [FixSource source = _v]) => FixRule.replace(observed, output, source);
FixRule _p(String observed, [FixSource source = _v]) => FixRule.preserve(observed, source);

void main() {
  final cases = <(String, List<FixRule>, String, String, List<(String before, String after)>)>[
    ('longest match', [_r('徐逊', '徐迅'), _r('徐逊说', 'X')], '徐逊说了', 'X了', [('徐逊说', 'X')]),
    ('overlap goes left to right', [_r('甲乙', '1'), _r('乙丙', '2')], '甲乙丙', '1丙', [('甲乙', '1')]),
    ('latin needs a word end', [_r('cloud', 'Cloud')], 'cloudflare', 'cloudflare', []),
    ('latin needs a word start', [_r('cloud', 'Cloud')], 'icloud', 'icloud', []),
    ('CJK neighbours are word ends', [_r('cloud', 'Cloud')], '用cloud跑', '用Cloud跑', [('cloud', 'Cloud')]),
    ('punctuation is a word end', [_r('cloud', 'Cloud')], 'my cloud.', 'my Cloud.', [('cloud', 'Cloud')]),
    ('latin ignores case, output as written', [_r('himory', 'Hemory')], '打开 HIMORY', '打开 Hemory', [('HIMORY', 'Hemory')]),
    ('latin with a space inside', [_r('git hub', 'GitHub')], '推到 Git Hub 上', '推到 GitHub 上', [('Git Hub', 'GitHub')]),
    ('already right is no change', [_r('cloud', 'Cloud')], 'Cloud', 'Cloud', []),
    ('non-latin compares exactly', [_r('A股', 'A 股')], 'a股', 'a股', []),
    ('non-latin starting with a capital', [_r('Java斯克', 'JavaScript')], '用Java斯克写', '用JavaScript写',
        [('Java斯克', 'JavaScript')]),
    ('latin and punctuation starting with a capital', [_r('VS-Code', 'VS Code')], '打开VS-Code', '打开VS Code',
        [('VS-Code', 'VS Code')]),
    ('non-latin capital compares exactly', [_r('java斯克', 'JavaScript')], '用Java斯克写', '用Java斯克写', []),
    ('non-latin capital compares exactly, the other way', [_r('Java斯克', 'JavaScript')], '用java斯克写', '用java斯克写', []),
    ('a preserve starting with a capital holds', [_p('C语言'), _r('语言', 'Y')], 'C语言', 'C语言', []),
    ('preserve blocks a shorter replace', [_p('黑猫瑞'), _r('猫瑞', 'Hemory')], '黑猫瑞', '黑猫瑞', []),
    ('replace starting before a preserve and overlapping it', [_p('猫瑞'), _r('黑猫', 'X')], '黑猫瑞', '黑猫瑞', []),
    ('a shorter replace that misses the preserve still applies', [_p('猫瑞'), _r('白黑猫', 'Y'), _r('白黑', 'X')], '白黑猫瑞',
        'X猫瑞', [('白黑', 'X')]),
    ('every occurrence', [_r('拍森', 'Python')], '拍森和拍森', 'Python和Python', [('拍森', 'Python'), ('拍森', 'Python')]),
    ('later duplicate wins', [_r('拍森', 'Pysen'), _r('拍森', 'Python')], '拍森', 'Python', [('拍森', 'Python')]),
    ('later preserve wins over the same replace', [_r('拍森', 'Python'), _p('拍森')], '拍森', '拍森', []),
  ];
  for (final (name, rules, input, text, changes) in cases) {
    test(name, () {
      final r = VoiceRules.compile(rules).fix(input);
      expect(r.text, text);
      expect(r.changes.map((c) => (c.before, c.after)).toList(), changes);
      expect(r.changed, changes.isNotEmpty);
    });
  }

  test('mixed text: rune offsets in the fixed text, and the source', () {
    final r = VoiceRules.compile([_r('拍森', 'Python', _l), _r('徐逊', '徐迅')]).fix('徐逊用拍森跑');
    expect(r.text, '徐迅用Python跑');
    expect(r.changes, [const FixChange(0, 2, '徐逊', '徐迅', _v), const FixChange(3, 9, '拍森', 'Python', _l)]);
    for (final c in r.changes) {
      expect(String.fromCharCodes(r.text.runes.toList().sublist(c.start, c.end)), c.after);
    }
  });

  test('offsets are runes past an emoji', () {
    final c = VoiceRules.compile([_r('拍森', 'Python')]).fix('😀用拍森跑').changes.single;
    expect((c.start, c.end), (2, 8));
  });

  test('compile drops rules under 2 chars without spaces', () {
    final rules = VoiceRules.compile([_r('在', '再'), _r('王 ', '汪'), _p(' a ')]);
    expect(rules.rules, isEmpty);
    expect(rules.isEmpty, isTrue);
    expect(rules.fix('在王 a').text, '在王 a');
  });

  test('compile keeps the last of the same observed, latin by case', () {
    final rules = VoiceRules.compile([_r('Cloud', 'X'), _r('徐逊', '徐迅'), _r('cloud', 'Cloud')]);
    expect(rules.rules, [_r('徐逊', '徐迅'), _r('cloud', 'Cloud')]);
  });

  test('empty rules', () {
    final r = VoiceRules.empty.fix('x');
    expect(r.text, 'x');
    expect(r.changes, isEmpty);
    expect(r.changed, isFalse);
    expect(VoiceRules.empty.isEmpty, isTrue);
  });

  test('FixRule json round trip', () {
    for (final rule in [_r('拍森', 'Python', _l), _p('黑猫瑞')]) {
      expect(FixRule.fromJson(rule.toJson()), rule);
    }
    expect(_p('黑猫瑞').toJson(), {'action': 'preserve', 'observed': '黑猫瑞', 'source': 'vocabulary'});
    expect(FixRule.fromJson({'action': 'replace', 'observed': '徐逊', 'output': '徐迅', 'source': 'vocabulary'}),
        _r('徐逊', '徐迅'));
  });

  test('FixRule.fromJson refuses what it does not know', () {
    for (final j in <Map<String, Object?>>[
      {'action': 'delete', 'observed': '徐逊', 'source': 'vocabulary'},
      {'action': 'replace', 'observed': '徐逊', 'output': '徐迅', 'source': 'note'},
      {'action': 'replace', 'observed': '徐逊', 'source': 'vocabulary'},
      {'action': 'preserve', 'source': 'learned'},
      {'action': 'replace', 'observed': '徐逊', 'output': 3, 'source': 'vocabulary'},
    ]) {
      expect(() => FixRule.fromJson(j), throwsFormatException, reason: '$j');
    }
  });

  test('fromVocabulary: the heard span touches a word the vocabulary fixes in the heard text', () {
    final rules = VoiceRules.compile(
        [_r('徐逊', '徐迅'), _r('拍森', 'Python', _l), _r('himory', 'Hemory'), _r('拍森脚本', 'Python脚本')]);
    expect(rules.fromVocabulary('徐逊', '徐逊'), isTrue);
    expect(rules.fromVocabulary('叫徐逊来', '叫徐逊来'), isTrue, reason: 'a diff wider than the rule');
    expect(rules.fromVocabulary('打开 HIMORY', 'HIMORY'), isTrue);
    expect(rules.fromVocabulary('运行一下拍森脚本看看结果', '拍森'), isTrue, reason: 'a diff narrower than the rule');
    expect(rules.fromVocabulary('运行一下拍森脚本看看结果', '森脚'), isTrue);
    expect(rules.fromVocabulary('😀运行拍森脚本', '拍森'), isTrue, reason: 'rune offsets');
    expect(rules.fromVocabulary('用拍森跑', '拍森'), isFalse, reason: 'learned');
    expect(rules.fromVocabulary('徐逊来了', '来了'), isFalse, reason: 'next to the fix, not on it');
    expect(rules.fromVocabulary('himoryx', 'himoryx'), isFalse, reason: 'no word end');
    expect(rules.fromVocabulary('徐逊来了', '黑猫瑞'), isFalse, reason: 'not in the heard text');
    final held = VoiceRules.compile([_p('徐逊说'), _r('徐逊', '徐迅')]);
    expect(held.fromVocabulary('徐逊说了', '徐逊'), isFalse, reason: 'a preserve kept the vocabulary from fixing it');
  });

  test('VoiceHeard', () {
    expect(const VoiceHeard(heard: '拍森', fixed: 'Python').changed, isTrue);
    expect(const VoiceHeard(heard: '拍森', fixed: '拍森').changed, isFalse);
  });

  test('1000 rules on 500 chars stays under 5 ms', () {
    final rnd = Random(7);
    String cjk(int n) => String.fromCharCodes([for (var i = 0; i < n; i++) 0x4E00 + rnd.nextInt(300)]);
    final list = [for (var i = 0; i < 1000; i++) _r(cjk(2 + rnd.nextInt(5)), 'X$i')];
    final rules = VoiceRules.compile(list);
    // Half the text is rule words, so fix really replaces.
    final b = StringBuffer();
    while (b.toString().runes.length < 500) {
      b.write(rnd.nextBool() ? list[rnd.nextInt(list.length)].observed : cjk(3));
    }
    final text = String.fromCharCodes(b.toString().runes.take(500));
    expect(rules.fix(text).changes.length, greaterThan(20));
    for (var i = 0; i < 5; i++) {
      rules.fix(text);
    }
    final times = <int>[];
    for (var i = 0; i < 20; i++) {
      final w = Stopwatch()..start();
      rules.fix(text);
      times.add(w.elapsedMicroseconds);
    }
    times.sort();
    final median = times[times.length ~/ 2];
    // ignore: avoid_print
    print('voice_fix: ${rules.rules.length} rules, 500 chars, median ${median}us');
    expect(median, lessThan(5000));
  });
}
