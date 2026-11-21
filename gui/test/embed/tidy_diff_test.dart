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
  test('editLearns: flipping the AI back to the heard words learns nothing', () => expect(editLearns('用拍森跑', '用Python跑', '用拍森跑'), isEmpty));
  test('editLearns: at most 3', () => expect(editLearns('甲甲和你说乙乙和你说丙丙和你说丁丁和你说', '甲甲和你说乙乙和你说丙丙和你说丁丁和你说', 'AA和你说BB和你说CC和你说DD和你说').map((i) => i.observed), ['甲甲', '乙乙', '丙丙']));

  test('LearnItem json and label', () {
    const r = LearnItem.replace(observed: '拍森', output: 'Python', excerpt: 'x');
    expect(r.toJson(), {'action': 'replace', 'observed': '拍森', 'output': 'Python', 'excerpt': 'x'});
    expect(r.label, '拍森 → Python');
    const p = LearnItem.preserve(observed: '黑猫瑞', avoid: 'Hemory', excerpt: 'x');
    expect(p.toJson(), {'action': 'preserve', 'observed': '黑猫瑞', 'avoid': 'Hemory', 'excerpt': 'x'});
    expect(p.label, '不改：黑猫瑞');
  });
}
