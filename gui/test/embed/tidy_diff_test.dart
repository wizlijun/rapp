import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/tidy_diff.dart';

void main() {
  final cases = <(String, String, String, List<(String before, String after)>)>[
    ('homophone grows to 2 chars, to the left first', '我门明天开会', '我们明天开会', [('我门', '我们')]),
    ('names', '明天用拍森跑一下黑猫瑞', '明天用Python跑一下Hemory', [('拍森', 'Python'), ('黑猫瑞', 'Hemory')]),
    ('filler deleted is no change', '嗯那个我们明天开会', '我们明天开会', []),
    ('punctuation only', '明天开会', '明天开会。', []),
    ('case and space only', '用git hub', '用GitHub', []),
    ('numbered lines', '第一买菜第二做饭', '1. 买菜\n2. 做饭', []),
    ('rewritten', '我觉得吧这个事情其实还是要再想一想比较好', '这件事需要再考虑。', []),
    ('more than 8', '一甲二乙三丙四丁五戊六己七庚八辛九壬', '一a二b三c四d五e六f七g八h九i', []),
    ('a side over 12 chars', '明天把它拿来', '明天把那个特别特别特别长名字的东西拿来', []),
  ];
  for (final (name, o, r, want) in cases) {
    test(name, () => expect(tidyChanges(o, r).map((c) => (c.before, c.after)).toList(), want));
  }

  test('tidyChanges keeps rune offsets past an emoji', () {
    final c = tidyChanges('😀用拍森跑', '😀用Python跑').single;
    expect((c.start, c.end), (2, 8));
  });

  test('editLearns: a word the AI left, the user fixed, maps to the heard words', () {
    expect(editLearns('明天跑一下黑猫瑞', '明天跑一下黑猫瑞。', '明天跑一下Hemory。'),
        [const LearnItem.replace(observed: '黑猫瑞', output: 'Hemory', excerpt: '明天跑一下黑猫瑞')]);
  });
  test('editLearns: a fix on the AI\'s own change learns from the heard words', () {
    expect(editLearns('明天用拍森跑', '明天用Pyson跑', '明天用Python跑'),
        [const LearnItem.replace(observed: '拍森', output: 'Python', excerpt: '明天用拍森跑')]);
  });
  test('editLearns: a fix on words the AI added is dropped', () => expect(editLearns('明天开会', '明天下午开会', '明天晚上开会'), isEmpty));
  // Empty because so short a text is mostly rewritten (`_changes`' guard); a longer revert teaches preserve (below).
  test('editLearns: flipping the AI back to the heard words learns nothing', () => expect(editLearns('用拍森跑', '用Python跑', '用拍森跑'), isEmpty));
  test('editLearns: reverting a fix teaches preserve', () => expect(editLearns('我们现在打开拍森看看', '我们现在打开Python看看', '我们现在打开拍森看看'),
      [const LearnItem.preserve(observed: '拍森', avoid: 'Python', excerpt: '我们现在打开拍森看看')]));
  test('editLearns: no fix, an edit teaches replace', () => expect(editLearns('我们现在打开黑猫瑞看看', '我们现在打开黑猫瑞看看', '我们现在打开Hemory看看'),
      [const LearnItem.replace(observed: '黑猫瑞', output: 'Hemory', excerpt: '我们现在打开黑猫瑞看看')]));
  test('editLearns: a revert next to a fix of its own teaches both', () => expect(editLearns('明天我们用拍森跑一下黑猫瑞的测试', '明天我们用Python跑一下黑猫瑞的测试', '明天我们用拍森跑一下Hemory的测试'), [
        const LearnItem.preserve(observed: '拍森', avoid: 'Python', excerpt: '明天我们用拍森跑一下黑猫瑞的测试'),
        const LearnItem.replace(observed: '黑猫瑞', output: 'Hemory', excerpt: '明天我们用拍森跑一下黑猫瑞的测试'),
      ]));
  test('editLearns: a fix left as it was teaches nothing', () => expect(editLearns('我们现在打开拍森看看', '我们现在打开Python看看', '我们现在打开Python看看'), isEmpty));
  test('editLearns: at most 3', () => expect(editLearns('甲甲和你说乙乙和你说丙丙和你说丁丁和你说', '甲甲和你说乙乙和你说丙丙和你说丁丁和你说', 'AA和你说BB和你说CC和你说DD和你说').map((i) => i.observed), ['甲甲', '乙乙', '丙丙']));

  test('tidyChanges widens a 1-rune AI side to the right at the very start', () {
    final c = tidyChanges('门口见面', '们口见面').single;
    expect((c.start, c.end, c.before, c.after), (0, 2, '门口', '们口'));
  });

  test('tidyChanges widens a 1-rune AI side to the left at the very end', () {
    final c = tidyChanges('明天开会门', '明天开会们').single;
    expect((c.start, c.end, c.before, c.after), (3, 5, '会门', '会们'));
  });

  test('tidyChanges merges two widened changes; after is the result runes [start, end)', () {
    const result = '们和们好好';
    final c = tidyChanges('门和门好好', result).single;
    expect((c.start, c.end, c.before, c.after), (0, 3, '门和门', '们和们'));
    expect(c.after, String.fromCharCodes(result.runes.toList().sublist(c.start, c.end)));
  });

  test('tidyChanges: a huge input is over the guard and returns nothing', () {
    final a = '甲' * 2100, b = '${'甲' * 1000}乙乙${'甲' * 1098}';
    expect(tidyChanges(a, b), isEmpty);
    expect(tidyChanges('${'甲' * 1000}丙丙${'甲' * 98}', '${'甲' * 1000}乙乙${'甲' * 98}').length, 1);
  });

  test('editLearns trims the output like the observed words', () {
    final l = editLearns('用拍森跑', '用Python跑', '用 派森\n 跑');
    for (final i in l) {
      expect(i.output, i.output!.trim());
    }
  });

  test('LearnItem json and label', () {
    const r = LearnItem.replace(observed: '拍森', output: 'Python', excerpt: 'x');
    expect(r.toJson(), {'action': 'replace', 'observed': '拍森', 'output': 'Python', 'excerpt': 'x'});
    expect(r.label, '拍森 → Python');
    const p = LearnItem.preserve(observed: '黑猫瑞', avoid: 'Hemory', excerpt: 'x');
    expect(p.toJson(), {'action': 'preserve', 'observed': '黑猫瑞', 'avoid': 'Hemory', 'excerpt': 'x'});
    expect(p.label, '不改：黑猫瑞');
  });

  group('learn excerpt is clipped around the word', () {
    String pad(int n) => List.generate(n, (i) => '天地玄黄宇宙洪荒'[i % 8]).join();

    test('a 1900 rune original gives a clipped excerpt that holds observed', () {
      final o = '${pad(1500)}拍森${pad(398)}', r = '${pad(1500)}Python${pad(398)}';
      expect(o.runes.length, 1900); // the aligner refuses far more than ~2000 runes
      final item = editLearns(o, o, r).single;
      expect(item.observed, '拍森');
      expect(item.excerpt.runes.length, lessThanOrEqualTo(402));
      expect(item.excerpt.runes.length, lessThanOrEqualTo(2000));
      expect(item.excerpt, contains('拍森'));
    });

    test('a short original keeps its full excerpt', () {
      expect(editLearns('明天用拍森跑', '明天用拍森跑', '明天用Python跑').single.excerpt, '明天用拍森跑');
    });

    test('an emoji at the window edge is not split', () {
      final text = '${'😀' * 200}拍森${'😀' * 200}x';
      for (final w in [199, 200, 201]) {
        final e = learnExcerpt(text, '拍森', window: w);
        expect(e, contains('拍森'));
        expect(e.runes.every((c) => c == 0x1F600 || '拍森x'.runes.contains(c)), isTrue);
      }
      final e = learnExcerpt('${'😀' * 300}拍森${'😀' * 300}', '拍森');
      expect(e.runes.length, 402);
      expect(e.runes.where((c) => c == 0x1F600).length, 400);
    });
  });
}
