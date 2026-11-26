import '../hub_client.dart';

/// An AI CLI whose commands the 常用语条 can translate.
class AgentTool {
  const AgentTool(this.id, this.name, {required this.apps, required this.progs});
  final String id, name;

  /// OSC 7501 `app` values the tool reports.
  final List<String> apps;

  /// Foreground program names.
  final List<String> progs;
}

const agentTools = <AgentTool>[
  AgentTool('claude-code', 'Claude Code', apps: ['claude-code'], progs: ['claude']),
  AgentTool('codex', 'Codex', apps: ['codex'], progs: ['codex']),
  AgentTool('gemini', 'Gemini CLI', apps: ['gemini', 'gemini-cli'], progs: ['gemini']),
  AgentTool('agy', 'Antigravity', apps: ['agy', 'antigravity'], progs: ['agy']),
  AgentTool('opencode', 'opencode', apps: ['opencode'], progs: ['opencode']),
];

/// The tool in front of a terminal row; null for none, a dead row or the session's own shell (a stale `ps` survives
/// the program's exit, so the shell wins over it).
AgentTool? toolOf(TermRow? row) {
  if (row == null || row.dead || row.shell == true) return null;
  final app = row.ps?.app;
  if (app != null) {
    for (final t in agentTools) {
      if (t.apps.contains(app)) return t;
    }
  }
  final fg = row.fg;
  if (fg != null) {
    for (final t in agentTools) {
      if (t.progs.contains(fg)) return t;
    }
  }
  return null;
}
