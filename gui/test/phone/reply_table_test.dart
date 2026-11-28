import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/strip_tools.dart';
import 'package:rapp/phone/reply_table.dart';

AgentTool t(String id) => agentTools.firstWhere((e) => e.id == id);

void main() {
  final cc = t('claude-code'), codex = t('codex'), agy = t('agy');

  group('toolKeysOf', () {
    test('claude-code', () {
      final k = toolKeysOf(cc)!;
      expect(k.allow, ['1']);
      expect(k.deny, ['Esc']);
      expect(k.options, isTrue);
      expect(k.planOk, ['2']);
      expect(k.planRevise, ['3']);
    });
    test('codex all null', () {
      final k = toolKeysOf(codex)!;
      expect(k.allow, isNull);
      expect(k.deny, isNull);
      expect(k.options, isFalse);
      expect(k.planOk, isNull);
      expect(k.planRevise, isNull);
    });
    test('agy', () {
      final k = toolKeysOf(agy)!;
      expect(k.allow, ['1']);
      expect(k.deny, isNull);
      expect(k.options, isFalse);
      expect(k.planOk, isNull);
    });
    test('others null', () {
      expect(toolKeysOf(t('gemini')), isNull);
      expect(toolKeysOf(t('opencode')), isNull);
      expect(toolKeysOf(null), isNull);
    });
  });

  group('denyKeysFor', () {
    test('per tool', () {
      expect(denyKeysFor(cc, 'approve Bash: ls'), ['Esc']);
      expect(denyKeysFor(agy, 'Approve Edit: Write: /a'), ['2']);
      expect(denyKeysFor(agy, 'Approve Bash: ls'), ['Esc']);
      expect(denyKeysFor(codex, 'x'), isEmpty);
      expect(denyKeysFor(t('gemini'), 'x'), isEmpty);
    });
  });

  group('parseAsk', () {
    test('cc approve', () {
      final a = parseAsk(cc, 'permission', 'approve Bash: touch a101.txt') as AskApprove;
      expect(a.tool, 'Bash');
      expect(a.target, 'touch a101.txt');
    });
    test('cc plan', () {
      expect(parseAsk(cc, 'permission', 'approve plan'), isA<AskPlan>());
    });
    test('cc options', () {
      final a = parseAsk(cc, 'question', 'answer: 迁移脚本用哪种写法？ (SQL · Rust · 先不迁)') as AskOptions;
      expect(a.question, '迁移脚本用哪种写法？');
      expect(a.options, ['SQL', 'Rust', '先不迁']);
    });
    test('options nulls', () {
      expect(parseAsk(cc, 'question', 'answer: q (a · b · c · d · e)'), isNull);
      expect(parseAsk(cc, 'question', 'answer: q (a · b'), isNull);
      expect(parseAsk(cc, 'question', 'answer: q (a·b·c)'), isNull);
    });
    test('trust folder', () {
      expect(parseAsk(cc, 'permission', 'approve: trust this folder'), isNull);
      expect(parseAsk(agy, 'permission', 'Trust this folder?'), isNull);
    });
    test('agy', () {
      final a = parseAsk(agy, 'permission', 'Approve Edit: Write: /a/b.txt') as AskApprove;
      expect(a.tool, 'Edit');
      expect(a.target, 'Write: /a/b.txt');
      expect(parseAsk(agy, 'permission', 'Approve plan'), isNull);
    });
    test('codex, gemini, empty', () {
      expect(parseAsk(codex, 'permission', 'approve Bash: ls'), isNull);
      expect(parseAsk(t('gemini'), 'permission', 'approve Bash: ls'), isNull);
      expect(parseAsk(cc, 'permission', ''), isNull);
    });
  });

  group('riskOf', () {
    test('hits', () {
      expect(riskOf('git push origin main')!.why, '推上去以后收不回来');
      expect(riskOf('cargo test && git push'), isNotNull);
      expect(riskOf('ls; rm x'), isNotNull);
      expect(riskOf('cat a | rm b'), isNotNull);
      expect(riskOf('rm -rf build')!.why, '删掉的找不回来');
      expect(riskOf('git reset --hard HEAD~1'), isNotNull);
      expect(riskOf('git clean -fd'), isNotNull);
      expect(riskOf('curl -X POST http://x'), isNotNull);
      expect(riskOf('curl -d x http://x'), isNotNull);
      expect(riskOf('curl --data-binary x http://x'), isNotNull);
      expect(riskOf('npm publish')!.why, '发布出去就收不回来');
      expect(riskOf('gh pr merge 3'), isNotNull);
      expect(riskOf('gh release create v1'), isNotNull);
      expect(riskOf('psql -c "DROP TABLE t"')!.why, '数据删了找不回来');
    });
    test('misses', () {
      expect(riskOf('git reset --soft HEAD~1'), isNull);
      expect(riskOf('curl https://x'), isNull);
      expect(riskOf('echo dropped'), isNull);
      expect(riskOf('firmware --rm'), isNull);
      expect(riskOf('cargo test'), isNull);
    });
    test('wrappers and prefixes', () {
      expect(riskOf('sudo rm -rf x')!.why, '删掉的找不回来');
      expect(riskOf('sudo -u bob rm x')!.why, '删掉的找不回来');
      expect(riskOf('xargs rm')!.why, '删掉的找不回来');
      expect(riskOf('FOO=1 git push')!.why, '推上去以后收不回来');
      expect(riskOf('git -C dir push')!.why, '推上去以后收不回来');
      expect(riskOf('git -c a=b push')!.why, '推上去以后收不回来');
      expect(riskOf('env X=1 npm publish')!.why, '发布出去就收不回来');
      expect(riskOf('nohup time sudo rm x'), isNotNull);
    });
    test('wrapper negatives', () {
      expect(riskOf('rmdir x'), isNull);
      expect(riskOf('git rm --cached a'), isNull);
      expect(riskOf('drop_table'), isNull);
      expect(riskOf('sudo ls'), isNull);
    });
    test('newline and single ampersand split', () {
      expect(riskOf('ls\nrm -rf x')!.why, '删掉的找不回来');
      expect(riskOf('a & rm x')!.why, '删掉的找不回来');
      expect(riskOf('cargo test && git push')!.why, '推上去以后收不回来');
    });
    test('first hit in segment order', () {
      expect(riskOf('git push && rm x')!.why, '推上去以后收不回来');
    });
  });

  group('plainWords', () {
    test('table', () {
      expect(plainWords('cargo test -p x'), '想跑测试');
      expect(plainWords('git push origin main'), '想把改动推到远端');
      expect(plainWords('cargo build'), '想编译');
      expect(plainWords('git commit -m x'), '想提交改动');
      expect(plainWords('rm a'), '想删文件');
      expect(plainWords('pip install x'), '想装依赖');
      expect(plainWords('ls'), isNull);
      expect(plainWords('ls && cargo test'), '想跑测试');
      expect(plainWords('sudo cargo test'), '想跑测试');
      expect(plainWords('git -C d push'), '想把改动推到远端');
    });
    test('tool names', () {
      expect(plainWordsForTool('Write'), '想改文件');
      expect(plainWordsForTool('Edit'), '想改文件');
      expect(plainWordsForTool('Read'), '想读文件');
      expect(plainWordsForTool('Bash'), isNull);
    });
  });

  group('doneLine', () {
    test('cases', () {
      expect(doneLine(null), '做完了');
      expect(doneLine(''), '做完了');
      expect(doneLine('改好了 [a.dart](file:///x/a.dart)'), '改好了 a.dart');
    });
  });

  test('no 安全 in table text', () {
    final all = StringBuffer();
    for (final c in ['git push', 'rm x', 'git clean', 'git reset --hard', 'npm publish', 'cargo publish',
      'curl -X POST', 'gh pr merge', 'gh release', 'drop', 'cargo test', 'git commit']) {
      all.write(riskOf(c)?.why ?? '');
      all.write(plainWords(c) ?? '');
    }
    expect(all.toString().contains('安全'), isFalse);
  });
}
