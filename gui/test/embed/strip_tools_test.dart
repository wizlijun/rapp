import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/strip_tools.dart';
import 'package:rapp/hub_client.dart';

TermRow row({TermPs? ps, String? fg, bool? shell, bool dead = false}) =>
    TermRow('term:pty:w', 'w', 'zsh', null, 1, 1, 0, dead, false, ps: ps, fg: fg, shell: shell);

void main() {
  test('toolOf', () {
    expect(toolOf(null), isNull);
    expect(toolOf(row(shell: true, fg: 'zsh', ps: const TermPs('done', app: 'claude-code'))), isNull);
    expect(toolOf(row(shell: false, fg: 'node', ps: const TermPs('working', app: 'claude-code')))?.id, 'claude-code');
    expect(toolOf(row(shell: false, fg: 'codex'))?.id, 'codex');
    expect(toolOf(row(shell: null, fg: 'claude'))?.id, 'claude-code');
    expect(toolOf(row(shell: false, fg: 'vim')), isNull);
    expect(toolOf(row(fg: 'claude', ps: const TermPs('idle', app: 'codex')))?.id, 'claude-code');
    expect(toolOf(row(fg: 'vim', ps: const TermPs('idle', app: 'claude-code'))), isNull);
    expect(toolOf(row(fg: 'ssh', ps: const TermPs('idle', app: 'claude-code'))), isNull);
    expect(toolOf(row(fg: 'node', ps: const TermPs('idle', app: 'claude-code')))?.id, 'claude-code');
    expect(toolOf(row(fg: null, ps: const TermPs('idle', app: 'claude-code')))?.id, 'claude-code');
    expect(toolOf(row(fg: 'claude', ps: const TermPs('idle', app: 'claude-code')))?.id, 'claude-code');
    expect(toolOf(row(dead: true, shell: false, fg: 'claude')), isNull);
  });
}
