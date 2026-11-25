import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/term_status.dart';

TermRow row({TermPs? ps, bool unread = false, bool dead = false, int ago = 5}) =>
    TermRow('term:pty:w', 'w', 'sh', null, 1, 1, 1000 - ago, dead, unread, ps: ps);

void main() {
  test('blocked', () {
    expect(termStatus(row(ps: const TermPs('blocked', kind: 'permission', msg: 'approve Bash: ls')), 1000), '等确认 · approve Bash: ls');
    expect(termStatus(row(ps: const TermPs('blocked', kind: 'question')), 1000), '在提问');
    expect(termStatus(row(ps: const TermPs('blocked', kind: 'auth')), 1000), '要登录');
    expect(termStatus(row(ps: const TermPs('blocked')), 1000), '在等你');
    expect(termLamp(row(ps: const TermPs('blocked')), 1000), Lamp.waiting);
  });
  test('working ignores quiet time', () {
    expect(termStatus(row(ps: const TermPs('working'), ago: 900), 1000), '在干活');
    expect(termStatus(row(ps: const TermPs('working', progress: 42)), 1000), '在干活 · 42%');
    expect(termLamp(row(ps: const TermPs('working'), ago: 900), 1000), Lamp.active);
  });
  test('error, done, idle', () {
    expect(termStatus(row(ps: const TermPs('error', msg: 'API Error: 400')), 1000), '出错 · API Error: 400');
    expect(termStatus(row(ps: const TermPs('error')), 1000), '出错');
    expect(termLamp(row(ps: const TermPs('error')), 1000), Lamp.idle);
    expect(termLamp(row(ps: const TermPs('error'), unread: true), 1000), Lamp.waiting);
    expect(termStatus(row(ps: const TermPs('done'), unread: true), 1000), '未读');
    expect(termLamp(row(ps: const TermPs('done'), unread: true), 1000), Lamp.waiting);
    expect(termLamp(row(ps: const TermPs('idle'), ago: 1), 1000), Lamp.idle);
  });
  test('dead wins', () {
    expect(termStatus(row(ps: const TermPs('blocked'), dead: true), 1000), '已退出');
    expect(termLamp(row(ps: const TermPs('blocked'), dead: true), 1000), Lamp.disconnected);
  });
}
