import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/embed/strip_tools.dart';

AgentTool tool(String id) => agentTools.firstWhere((t) => t.id == id);

void main() {
  final claude = tool('claude-code'), codex = tool('codex');

  test('the built-in table follows spec §7', () {
    expect(actionFor(const StripCmd('new'), claude), const CmdText('/clear'));
    expect(actionFor(const StripCmd('new'), codex), const CmdText('/new'));
    expect(actionFor(const StripCmd('search'), claude), const CmdKey('cr'));
    expect(actionFor(const StripCmd('search'), tool('agy')), isNull);
    expect(actionFor(const StripCmd('compact'), tool('gemini')), const CmdText('/compress'));
    expect(actionFor(const StripCmd('usage'), tool('gemini')), const CmdText('/stats'));
    expect(actionFor(const StripCmd('model'), tool('opencode')), const CmdText('/models'));
    expect(actionFor(const StripCmd('resume'), tool('opencode')), const CmdText('/sessions'));
    expect(actionFor(const StripCmd('compact'), tool('opencode')), isNull);
    expect(actionFor(const StripCmd('usage'), tool('opencode')), isNull);
    expect(builtinCmdOrder.every(builtinCmds.containsKey), isTrue);
  });

  test('切模式 is a built-in command sending ⇧Tab on all five tools', () {
    expect(builtinCmds['mode']!.label, '切模式');
    for (final id in ['claude-code', 'codex', 'gemini', 'agy', 'opencode']) {
      expect(actionFor(const StripCmd('mode'), tool(id)), const CmdKey('stab'), reason: id);
    }
  });

  test('user overrides and custom commands', () {
    expect(actionFor(const StripCmd('new', per: {'codex': CmdText('/clear')}), codex), const CmdText('/clear'));
    expect(actionFor(const StripCmd('new', per: {'codex': null}), codex), isNull);
    expect(actionFor(const StripCmd('new', per: {'codex': null}), claude), const CmdText('/clear'));
    const u = StripCmd('u1', label: '审查', per: {'codex': CmdText('/review')});
    expect(actionFor(u, codex), const CmdText('/review'));
    expect(actionFor(u, claude), isNull);
    expect(u.labelOf(), '审查');
    expect(const StripCmd('new').labelOf(), '新对话');
    expect(const StripCmd('zz').labelOf(), 'zz');
    expect(const StripCmd('new').builtin, isTrue);
    expect(u.builtin, isFalse);
  });

  test('json round trips', () {
    for (final c in const [
      StripCmd('new'),
      StripCmd('new', per: {'codex': CmdText('/clear'), 'gemini': CmdKey('cr')}),
      StripCmd('u1', label: '审查', per: {'codex': CmdText('/review')}),
    ]) {
      expect(StripCmd.fromJson(c.toJson()), c);
    }
    final r = StripCmd.fromJson(const StripCmd('new', per: {'codex': null}).toJson())!;
    expect(r.per.containsKey('codex'), isTrue);
    expect(r.per['codex'], isNull);
  });

  test('bad json is dropped', () {
    expect(StripCmd.fromJson({'kind': 'cmd'}), isNull);
    expect(StripCmd.fromJson({'kind': 'cmd', 'id': ' '}), isNull);
    final c = StripCmd.fromJson({
      'kind': 'cmd',
      'id': 'x',
      'per': {'a': 3, 'b': {'key': 'zz'}, 'c': {'text': '/ok'}, 'd': {'text': ' '}},
    })!;
    expect(c.per, {'c': const CmdText('/ok')});
  });

  test('defaults and item parsing', () {
    expect(defaultStripItems.length, 14);
    expect(defaultStripItems[1], const StripCmd('mode'));
    expect(builtinCmdOrder, ['new', 'mode', 'model', 'compact', 'resume', 'usage', 'search']);
    expect(defaultStripItems.take(7), [for (final id in builtinCmdOrder) StripCmd(id)]);
    expect(defaultStripItems.skip(7), defaultPhrases);
    expect(defaultPhrases.map((p) => p.text).toList(),
        ['继续', '按你推荐来', '进度', '全做完别问我', '先写方案别改代码', '跑下测试', '提交并推送']);
    expect(stripItemFromJson({'kind': 'cmd', 'id': 'new'}), const StripCmd('new'));
    expect(stripItemFromJson({'text': 'a'}), const Phrase('a'));
    expect(stripItemFromJson(3), isNull);
  });
}
