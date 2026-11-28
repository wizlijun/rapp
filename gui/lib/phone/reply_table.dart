import '../embed/strip_tools.dart';

/// Keys one AI tool takes for the phone reply cards. A null list means the tool has no such key.
class ToolKeys {
  const ToolKeys({this.allow, this.deny, this.options = false, this.planOk, this.planRevise});

  final List<String>? allow;

  /// Null means "ask [denyKeysFor]" (agy: the key depends on the message). Claude Code's is fixed.
  final List<String>? deny;

  /// Whether the tool shows a numbered option list the card can answer.
  final bool options;
  final List<String>? planOk, planRevise;
}

const _claudeKeys = ToolKeys(
  allow: ['1'],
  deny: ['Esc'],
  options: true,
  planOk: ['2'],
  planRevise: ['3'],
);
const _codexKeys = ToolKeys();
const _agyKeys = ToolKeys(allow: ['1']);

/// Null for tools without a table (gemini, opencode, unknown).
ToolKeys? toolKeysOf(AgentTool? tool) => switch (tool?.id) {
      'claude-code' => _claudeKeys,
      'codex' => _codexKeys,
      'agy' => _agyKeys,
      _ => null,
    };

/// Keys that refuse an approval. Empty when the tool has no way to refuse.
List<String> denyKeysFor(AgentTool tool, String msg) => switch (tool.id) {
      'claude-code' => const ['Esc'],
      'agy' => msg.startsWith('Approve Edit:') ? const ['2'] : const ['Esc'],
      _ => const [],
    };

sealed class ParsedAsk {
  const ParsedAsk();
}

class AskApprove extends ParsedAsk {
  const AskApprove(this.tool, this.target);
  final String tool, target;
}

class AskOptions extends ParsedAsk {
  const AskOptions(this.question, this.options);
  final String question;
  final List<String> options;
}

class AskPlan extends ParsedAsk {
  const AskPlan();
}

final _ccApprove = RegExp(r'^approve (\S+?): (.+)$');
final _agyApprove = RegExp(r'^Approve (\S+?): (.+)$');
final _ccOptions = RegExp(r'^answer: (.*\S)\s+\((.*)\)$');

ParsedAsk? parseAsk(AgentTool tool, String? kind, String msg) {
  if (msg.isEmpty) return null;
  final lower = msg.toLowerCase();
  if (lower.contains('trust this folder')) return null;
  switch (tool.id) {
    case 'claude-code':
      if (kind == 'permission' && msg == 'approve plan') return const AskPlan();
      final a = _ccApprove.firstMatch(msg);
      if (a != null) return AskApprove(a[1]!, a[2]!);
      final o = _ccOptions.firstMatch(msg);
      if (o != null) {
        final inner = o[2]!;
        final opts = inner.split(' · ');
        if (opts.length < 2 || opts.length > 4) return null;
        if (opts.any((e) => e.isEmpty || e.contains('·') || e.contains('(') || e.contains(')'))) return null;
        return AskOptions(o[1]!, opts);
      }
      return null;
    case 'agy':
      final a = _agyApprove.firstMatch(msg);
      if (a != null) return AskApprove(a[1]!, a[2]!);
      return null;
    default:
      return null;
  }
}

final _split = RegExp(r'&&|\|\||;|\||\n|&');
final _assign = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');
const _wrappers = {'sudo', 'env', 'xargs', 'time', 'nohup', 'command'};
const _sudoArgFlags = {'-u', '-g', '-h', '-p', '-C', '-U', '-r', '-t'};

/// Drops `NAME=value` words, wrappers (`sudo`, `env`, `xargs`, ...) with their flags, and git's global options, so
/// the program word comes first.
String _normalise(String seg) {
  final t = seg.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
  var i = 0;
  while (i < t.length) {
    if (_assign.hasMatch(t[i])) {
      i++;
    } else if (_wrappers.contains(t[i])) {
      final w = t[i++];
      while (i < t.length && t[i].startsWith('-')) {
        final f = t[i++];
        if (w == 'sudo' && _sudoArgFlags.contains(f) && i < t.length) i++;
      }
    } else {
      break;
    }
  }
  final rest = t.sublist(i);
  if (rest.isNotEmpty && rest[0] == 'git') {
    var j = 1;
    while (j < rest.length && rest[j].startsWith('-')) {
      j += (rest[j] == '-C' || rest[j] == '-c') ? 2 : 1;
    }
    return ['git', ...rest.sublist(j > rest.length ? rest.length : j)].join(' ');
  }
  return rest.join(' ');
}

List<String> _segments(String command) =>
    command.split(_split).map((e) => _normalise(e.trim())).where((e) => e.isNotEmpty).toList();

bool _starts(String seg, String prefix) => seg == prefix || seg.startsWith('$prefix ');

const _plain = <(String, String)>[
  ('cargo test', '想跑测试'),
  ('flutter test', '想跑测试'),
  ('npm test', '想跑测试'),
  ('pytest', '想跑测试'),
  ('go test', '想跑测试'),
  ('cargo build', '想编译'),
  ('flutter build', '想编译'),
  ('npm run build', '想编译'),
  ('git commit', '想提交改动'),
  ('git push', '想把改动推到远端'),
  ('rm', '想删文件'),
  ('npm install', '想装依赖'),
  ('pip install', '想装依赖'),
  ('cargo add', '想装依赖'),
];

/// Plain words for a shell command (first matching segment); null when unknown.
String? plainWords(String command) {
  for (final seg in _segments(command)) {
    for (final (prefix, words) in _plain) {
      if (_starts(seg, prefix)) return words;
    }
  }
  return null;
}

/// Plain words for a tool name such as `Write`.
String? plainWordsForTool(String toolName) => switch (toolName) {
      'Write' || 'Edit' => '想改文件',
      'Read' => '想读文件',
      _ => null,
    };

const _risky = <(String, String)>[
  ('rm', '删掉的找不回来'),
  ('git clean', '删掉的找不回来'),
  ('git reset --hard', '删掉的找不回来'),
  ('git push', '推上去以后收不回来'),
  ('npm publish', '发布出去就收不回来'),
  ('cargo publish', '发布出去就收不回来'),
  ('gh pr merge', '合并以后要另做一次才能撤'),
  ('gh release', '发布了别人马上能看到'),
];

final _curlMethod = RegExp(r'^-X(POST|PUT|PATCH|DELETE)$');
final _dataWords = RegExp(r'\b(drop|delete|truncate)\b', caseSensitive: false);

bool _curlSends(String seg) {
  if (!_starts(seg, 'curl')) return false;
  final toks = seg.split(RegExp(r'\s+'));
  for (var i = 1; i < toks.length; i++) {
    final x = toks[i];
    if (x == '-d' || x == '-F' || x.startsWith('--data')) return true;
    if (_curlMethod.hasMatch(x)) return true;
    if (x == '-X' && i + 1 < toks.length && RegExp(r'^(POST|PUT|PATCH|DELETE)$').hasMatch(toks[i + 1])) return true;
  }
  return false;
}

/// The first can't-undo thing in the command, with the reason; null when none.
({String word, String why})? riskOf(String command) {
  for (final seg in _segments(command)) {
    for (final (prefix, why) in _risky) {
      if (_starts(seg, prefix)) return (word: prefix, why: why);
    }
    if (_curlSends(seg)) return (word: 'curl', why: '请求发出去就收不回来');
    final m = _dataWords.firstMatch(seg);
    if (m != null) return (word: m[0]!.toLowerCase(), why: '数据删了找不回来');
  }
  return null;
}

final _mdLink = RegExp(r'\[([^\]]*)\]\([^)]*\)');

/// One line for a finished turn; markdown links shrink to their text.
String doneLine(String? msg) {
  final s = (msg ?? '').replaceAllMapped(_mdLink, (m) => m[1]!).trim();
  return s.isEmpty ? '做完了' : s;
}
