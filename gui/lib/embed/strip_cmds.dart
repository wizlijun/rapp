// 常用语条 commands: intents ("新对话") that each AI tool spells its own way (`/clear`, `/new`, a key).
// Spec: docs/superpowers/specs/2026-11-26-rapp-strip-commands-design.md §6, §7, §10.
import 'key_bar_keys.dart';
import 'phrases.dart';
import 'strip_tools.dart';

/// How a command is written for one tool.
sealed class CmdAction {
  const CmdAction();
  Map<String, Object> toJson();

  /// Null for anything that is not `{text: non-blank}` or `{key: id of a barKeys key with a wire name}`.
  static CmdAction? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['text'];
    if (t is String && t.trim().isNotEmpty) return CmdText(t);
    final k = j['key'];
    if (k is String && barKeys[k]?.wire != null) return CmdKey(k);
    return null;
  }
}

/// Text sent as typed, then Return.
class CmdText extends CmdAction {
  const CmdText(this.text);
  final String text;

  @override
  Map<String, Object> toJson() => {'text': text};

  @override
  bool operator ==(Object other) => other is CmdText && other.text == text;

  @override
  int get hashCode => Object.hash('text', text);
}

/// One key of the key bar ([key] is a `barKeys` id such as `cr`).
class CmdKey extends CmdAction {
  const CmdKey(this.key);
  final String key;

  @override
  Map<String, Object> toJson() => {'key': key};

  @override
  bool operator ==(Object other) => other is CmdKey && other.key == key;

  @override
  int get hashCode => Object.hash('key', key);
}

/// One command of the strip. [label] null is the built-in face; a [per] entry missing follows the built-in table, one
/// present and null is the user clearing it (this tool has none).
class StripCmd implements StripItem {
  const StripCmd(this.id, {this.label, this.per = const {}});
  final String id;
  final String? label;
  final Map<String, CmdAction?> per;

  String labelOf() => label ?? builtinCmds[id]?.label ?? id;

  bool get builtin => builtinCmds.containsKey(id);

  @override
  Map<String, Object?> toJson() => {
        'kind': 'cmd',
        'id': id,
        if (label != null) 'label': label,
        if (per.isNotEmpty) 'per': {for (final e in per.entries) e.key: e.value?.toJson()},
      };

  /// Null without a non-blank id. A bad cell of `per` is dropped; an explicit null is kept.
  static StripCmd? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final l = j['label'];
    final p = j['per'];
    final per = <String, CmdAction?>{};
    if (p is Map) {
      for (final e in p.entries) {
        final k = e.key;
        if (k is! String) continue;
        if (e.value == null) {
          per[k] = null;
        } else {
          final a = CmdAction.fromJson(e.value);
          if (a != null) per[k] = a;
        }
      }
    }
    return StripCmd(id, label: l is String && l.trim().isNotEmpty ? l : null, per: per);
  }

  @override
  bool operator ==(Object other) {
    if (other is! StripCmd || other.id != id || other.label != label || other.per.length != per.length) return false;
    for (final e in per.entries) {
      if (!other.per.containsKey(e.key) || other.per[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(id, label, Object.hashAllUnordered(per.entries.map((e) => Object.hash(e.key, e.value))));
}

/// A built-in command: its face and what each tool that has it is sent. A tool missing from [per] has none.
class BuiltinCmd {
  const BuiltinCmd(this.label, this.per);
  final String label;
  final Map<String, CmdAction> per;
}

const builtinCmdOrder = ['new', 'mode', 'model', 'compact', 'resume', 'usage', 'search'];

// Verified against the tools' docs on 2026-11-26 (spec §7); primary command only.
const builtinCmds = <String, BuiltinCmd>{
  'new': BuiltinCmd('新对话', {
    'claude-code': CmdText('/clear'),
    'codex': CmdText('/new'),
    'gemini': CmdText('/clear'),
    'agy': CmdText('/clear'),
    'opencode': CmdText('/new'),
  }),
  // ⇧Tab; checked 2026-11-27 (spec §7): Claude Code cycles permission modes, Codex toggles plan, Gemini cycles
  // approval modes, Antigravity cycles default/accept-edits/plan, opencode switches agent.
  'mode': BuiltinCmd('切模式', {
    'claude-code': CmdKey('stab'),
    'codex': CmdKey('stab'),
    'gemini': CmdKey('stab'),
    'agy': CmdKey('stab'),
    'opencode': CmdKey('stab'),
  }),
  'model': BuiltinCmd('换模型', {
    'claude-code': CmdText('/model'),
    'codex': CmdText('/model'),
    'gemini': CmdText('/model'),
    'agy': CmdText('/model'),
    'opencode': CmdText('/models'),
  }),
  'compact': BuiltinCmd('压缩', {
    'claude-code': CmdText('/compact'),
    'codex': CmdText('/compact'),
    'gemini': CmdText('/compress'),
    'agy': CmdText('/compact'),
  }),
  'resume': BuiltinCmd('恢复', {
    'claude-code': CmdText('/resume'),
    'codex': CmdText('/resume'),
    'gemini': CmdText('/resume'),
    'agy': CmdText('/resume'),
    'opencode': CmdText('/sessions'),
  }),
  'usage': BuiltinCmd('用量', {
    'claude-code': CmdText('/usage'),
    'codex': CmdText('/usage'),
    'gemini': CmdText('/stats'),
    'agy': CmdText('/usage'),
  }),
  'search': BuiltinCmd('搜历史', {
    'claude-code': CmdKey('cr'),
    'codex': CmdKey('cr'),
    'gemini': CmdKey('cr'),
  }),
};

/// What [c] sends on [tool]; null when the tool has none.
CmdAction? actionFor(StripCmd c, AgentTool tool) =>
    c.per.containsKey(tool.id) ? c.per[tool.id] : builtinCmds[c.id]?.per[tool.id];

/// What a fresh install (and 恢复默认) holds: the seven commands, then the default phrases.
List<StripItem> get defaultStripItems => [for (final id in builtinCmdOrder) StripCmd(id), ...defaultPhrases];

StripItem? stripItemFromJson(Object? j) {
  if (j is Map && j['kind'] == 'cmd') return StripCmd.fromJson(j);
  return Phrase.fromJson(j);
}

/// How stars and counts name an item of the 常用语 doc (quick-row Ruling 1): `p:` and the phrase's id or the command's.
String refOf(StripItem it) => 'p:${it is StripCmd ? it.id : (it as Phrase).id ?? ''}';
