import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/projects.dart';
import 'package:rapp/ui/workspace_store.dart';

void main() {
  final p = Project('p', '写周报', [
    Member(const AppRef('111', 'a', 'Calculator')), // open already
    Member(const AppRef('111', 'b', 'Notes')), // disconnected → reconnect
    Member(const AppRef('222', 'c', 'Chess')), // offline → skip
    Member(const AppRef('222', 'd', 'Mail')), // offline → skip
    Member(const AppRef('111', 'e', 'Safari')), // not open → open
  ]);
  final lamps = {'111/a': Lamp.active, '111/b': Lamp.disconnected};
  String names(String id) => id == '222' ? 'studio' : 'mini';

  test('plan: open, reconnect, skip and stop', () {
    final plan = planOpenAll(p, lampOf: (k) => lamps[k], offline: (d) => d == '222');
    expect(plan.open.map((m) => m.key), ['111/b', '111/e']);
    expect(plan.first, '111/a');
    expect(plan.skipped, {'222': 2});
    expect(openAllHint(p, plan, names), '写周报：打开 2 个；studio 离线，跳过 2 个');
  });

  test('plan: a connecting member counts as open', () {
    final plan = planOpenAll(p, lampOf: (k) => k == '111/a' ? Lamp.connecting : null, offline: (d) => false);
    expect(plan.open.map((m) => m.key), ['111/b', '222/c', '222/d', '111/e']);
    expect(plan.first, '111/a');
    expect(plan.skipped, isEmpty);
  });

  test('plan: the first member not skipped is where it stops', () {
    final q = Project('q', '写周报', [
      Member(const AppRef('222', 'c', 'Chess')),
      Member(const AppRef('111', 'e', 'Safari')),
    ]);
    final plan = planOpenAll(q, lampOf: (k) => null, offline: (d) => d == '222');
    expect(plan.first, '111/e');
    expect(openAllHint(q, plan, names), '写周报：打开 1 个；studio 离线，跳过 1 个');
  });

  test('plan: skipped devices in the order they first appear', () {
    final q = Project('q', '写周报', [
      Member(const AppRef('333', 'x', 'X')),
      Member(const AppRef('222', 'c', 'Chess')),
      Member(const AppRef('333', 'y', 'Y')),
    ]);
    final plan = planOpenAll(q, lampOf: (k) => null, offline: (d) => true);
    expect(plan.skipped.keys, ['333', '222']);
    expect(openAllHint(q, plan, (id) => id), '写周报：333 离线，跳过 2 个；222 离线，跳过 1 个');
  });

  test('plan: all offline has no first', () {
    final q = Project('q', '写周报', [
      Member(const AppRef('111', 'a', 'Calculator')),
      Member(const AppRef('111', 'b', 'Notes')),
    ]);
    final plan = planOpenAll(q, lampOf: (k) => null, offline: (d) => true);
    expect(plan.open, isEmpty);
    expect(plan.first, isNull);
    expect(openAllHint(q, plan, names), '写周报：mini 离线，跳过 2 个');
  });

  test('hint: nothing to do', () {
    final all = planOpenAll(p, lampOf: (k) => Lamp.active, offline: (d) => d == '222');
    expect(all.open, isEmpty);
    expect(all.skipped, isEmpty);
    expect(all.first, '111/a');
    expect(openAllHint(p, all, names), '写周报：已经全部打开');
    final empty = Project('e', '写周报');
    expect(openAllHint(empty, planOpenAll(empty, lampOf: (k) => null, offline: (d) => false), names), '写周报：没有成员');
  });

  test('end all hints', () {
    expect(endAllHint('写周报', 3, 1), '写周报：结束 3 个会话，其中 1 个也属于别的项目');
    expect(endAllHint('写周报', 2, 0), '写周报：结束 2 个会话');
    expect(endAllHint('写周报', 0, 0), '写周报：没有要结束的会话');
  });
}
