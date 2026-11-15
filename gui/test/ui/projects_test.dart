import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/projects.dart';
import 'package:rapp/ui/session_model.dart';
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

  group('project subtitle', () {
    SessionEntry en(String key) {
      final i = key.indexOf('/');
      return SessionEntry(
          sid: 1, id: key.substring(0, i), app: key.substring(i + 1), appName: 'X',
          device: 'mini', path: 'lan', lamp: Lamp.active);
    }

    const a = AppRef('111', 'a', 'A');
    test('not in a project is null', () {
      expect(projectSubtitle(en('111/a'), [Project('p', '写周报')]), isNull);
    });
    test('one project, no task', () {
      expect(projectSubtitle(en('111/a'), [Project('p', '写周报', [Member(a)])]), 'mini · 写周报');
    });
    test('several projects add 等 and the first non-empty task', () {
      final p1 = Project('p', '写周报', [Member(a)]);
      final p2 = Project('q', '发版', [Member(a, '跑测试')]);
      expect(projectSubtitle(en('111/a'), [p1, p2]), 'mini · 写周报等 · 跑测试');
      final p3 = Project('p', '写周报', [Member(a, '整理 PR')]);
      expect(projectSubtitle(en('111/a'), [p3, p2]), 'mini · 写周报等 · 整理 PR');
    });
    test('the current project is the one named, still with 等', () {
      final p1 = Project('p', '写周报', [Member(a)]);
      final p2 = Project('q', '发版', [Member(a, '跑测试')]);
      expect(projectSubtitle(en('111/a'), [p1, p2], current: 'q'), 'mini · 发版等 · 跑测试');
      final p3 = Project('p', '写周报', [Member(a, '整理 PR')]);
      expect(projectSubtitle(en('111/a'), [p3, p2], current: 'q'), 'mini · 发版等 · 跑测试');
      // A current project the session is not in changes nothing.
      expect(projectSubtitle(en('111/a'), [p1, p2], current: 'x'), 'mini · 写周报等 · 跑测试');
    });
  });

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

  group('resumeKey', () {
    final p = Project('p', 'x', [Member(const AppRef('1', 'a', 'A')), Member(const AppRef('1', 'b', 'B')), Member(const AppRef('2', 'c', 'C'))]);
    test('last if still a member and open', () => expect(resumeKey(p, '1/b', (k) => true), '1/b'));
    test('first open member when last is closed', () => expect(resumeKey(p, '1/b', (k) => k == '2/c'), '2/c'));
    test('first open member when last left the project', () => expect(resumeKey(p, '9/z', (k) => true), '1/a'));
    test('null when nothing is open', () => expect(resumeKey(p, '1/b', (k) => false), isNull));
  });
  group('returnCue', () {
    final now = DateTime.utc(2026, 11, 14, 12);
    String? cue(Duration ago, [int n = 0, int d = 0]) => returnCue(leftAt: now.subtract(ago), now: now, needs: n, disconnected: d);
    test('minutes, hours, days', () {
      expect(cue(const Duration(minutes: 25)), '25 分钟前离开');
      expect(cue(const Duration(minutes: 119)), '1 小时前离开');
      expect(cue(const Duration(hours: 49)), '2 天前离开');
    });
    test('what changed', () {
      expect(cue(const Duration(minutes: 25), 1), '25 分钟前离开 · 这期间 1 个等你');
      expect(cue(const Duration(minutes: 25), 0, 2), '25 分钟前离开 · 这期间 2 个已断开');
      expect(cue(const Duration(minutes: 25), 1, 2), '25 分钟前离开 · 这期间 1 个等你、2 个已断开');
    });
    test('nothing under a minute, without a time, or with a time in the future', () {
      expect(cue(const Duration(seconds: 59)), isNull);
      expect(returnCue(leftAt: null, now: now, needs: 3, disconnected: 0), isNull);
      expect(returnCue(leftAt: now.add(const Duration(hours: 1)), now: now, needs: 0, disconnected: 0), isNull);
    });
  });
  test('orderedProjects: pinned first, order kept', () {
    final ps = [Project('a', 'A'), Project('b', 'B', [], true), Project('c', 'C'), Project('d', 'D', [], true)];
    expect(orderedProjects(ps).map((p) => p.id), ['b', 'd', 'a', 'c']);
  });
  test('projectKeys follows member order', () {
    expect(projectKeys(Project('p', 'x', [Member(const AppRef('2', 'c', 'C')), Member(const AppRef('1', 'a', 'A'))])), ['2/c', '1/a']);
  });
}
