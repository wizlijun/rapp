import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/session_model.dart';
import 'package:rapp/ui/workspace_store.dart';

SessionEntry e(String device, String appName) => SessionEntry(
    sid: 1, id: device, app: 'bundle.$appName', appName: appName,
    device: device, path: 'lan', lamp: Lamp.active);

void main() {
  test('groups by device, sorted, entries stable', () {
    final g = groupSessions([e('mini', 'Safari'), e('air', 'Notes'), e('mini', 'Mail')], Grouping.device);
    expect(g.map((x) => x.title), ['air', 'mini']);
    expect(g[1].entries.map((x) => x.appName), ['Mail', 'Safari']);
  });
  test('groups by app', () {
    final g = groupSessions([e('mini', 'Safari'), e('air', 'Safari')], Grouping.app);
    expect(g.single.title, 'Safari');
    expect(g.single.entries.map((x) => x.device), ['air', 'mini']);
  });
  test('stepKey cycles across groups both ways', () {
    final g = groupSessions([e('a', 'X'), e('b', 'Y'), e('b', 'Z')], Grouping.device);
    expect(stepKey(g, 'a/bundle.X', 1), 'b/bundle.Y');
    expect(stepKey(g, 'b/bundle.Z', 1), 'a/bundle.X');
    expect(stepKey(g, 'a/bundle.X', -1), 'b/bundle.Z');
    expect(stepKey(g, null, 1), 'a/bundle.X');
    expect(stepKey(const [], null, 1), isNull);
  });
  AppRef ref(String d, String n) => AppRef(d, 'bundle.$n', n);
  final projectsFixture = [
    Project('1', 'P1', [Member(ref('mini', 'Safari')), Member(ref('mini', 'Notes'))]),
    Project('2', 'P2', [Member(ref('mini', 'Notes'))]),
    Project('3', 'P3', [Member(ref('mini', 'Gone'))]),
  ];
  final three = [e('mini', 'Notes'), e('mini', 'Safari'), e('studio', 'Chess')];
  test('project grouping follows project and member order, 未归项目的 last', () {
    final g = groupSessions(three, Grouping.project, projects: projectsFixture);
    expect(g.map((x) => x.title), ['P1', 'P2', otherGroupTitle]);
    expect(g[0].entries.map((x) => x.appName), ['Safari', 'Notes']);
    expect(g[1].entries.map((x) => x.appName), ['Notes']);
    expect(g[2].entries.map((x) => x.appName), ['Chess']);
  });
  test('project grouping with no projects puts everything in 未归项目的', () {
    final g = groupSessions([e('studio', 'Chess'), e('mini', 'Notes')], Grouping.project);
    expect(g.single.title, otherGroupTitle);
    expect(g.single.entries.map((x) => x.appName), ['Notes', 'Chess']);
  });
  test('group projectId is set for project groups only', () {
    final g = groupSessions(three, Grouping.project, projects: projectsFixture);
    expect(g.map((x) => x.projectId), ['1', '2', null]);
    expect(groupSessions(three, Grouping.device).map((x) => x.projectId), [null, null]);
  });
  final trio = [
    Project('1', 'P1', [Member(ref('mini', 'Safari'))]),
    Project('2', 'P2', [Member(ref('mini', 'Notes'))], true),
    Project('3', 'P3', [Member(ref('studio', 'Chess'))]),
  ];
  test('by project: the current project first, then pinned, then the rest, 未归项目的 last', () {
    final all = [...three, e('air', 'Loose')];
    final g = groupSessions(all, Grouping.project, projects: trio, first: '3');
    expect(g.map((x) => x.title), ['P3', 'P2', 'P1', otherGroupTitle]);
  });
  test('by project without a current project: pinned first', () {
    expect(groupSessions(three, Grouping.project, projects: trio).map((x) => x.title), ['P2', 'P1', 'P3']);
  });
  test('first naming no project or a project with no open members changes nothing', () {
    final plain = groupSessions(three, Grouping.project, projects: trio).map((x) => x.title).toList();
    expect(groupSessions(three, Grouping.project, projects: trio, first: 'zz').map((x) => x.title), plain);
    final withEmpty = [...trio, Project('4', 'P4', [Member(ref('mini', 'Gone'))])];
    expect(groupSessions(three, Grouping.project, projects: withEmpty, first: '4').map((x) => x.title), plain);
  });
  test('stepKey within a project wraps and ignores sessions outside it', () {
    final g = groupSessions(three, Grouping.device);
    const within = ['mini/bundle.Notes', 'studio/bundle.Chess', 'mini/bundle.Gone'];
    expect(stepKey(g, 'mini/bundle.Notes', 1, within: within), 'studio/bundle.Chess');
    expect(stepKey(g, 'studio/bundle.Chess', 1, within: within), 'mini/bundle.Notes');
    expect(stepKey(g, 'mini/bundle.Safari', 1, within: within), 'mini/bundle.Notes');
    expect(stepKey(g, 'mini/bundle.Safari', -1, within: within), 'studio/bundle.Chess');
    expect(stepKey(g, 'mini/bundle.Safari', 1, within: const ['x/y']), isNull);
  });
  test('stepKey visits a session listed twice once', () {
    final g = groupSessions(three, Grouping.project, projects: projectsFixture);
    expect(stepKey(g, 'mini/bundle.Safari', 1), 'mini/bundle.Notes');
    expect(stepKey(g, 'mini/bundle.Notes', 1), 'studio/bundle.Chess');
    expect(stepKey(g, 'studio/bundle.Chess', 1), 'mini/bundle.Safari');
    expect(stepKey(g, 'studio/bundle.Chess', -1), 'mini/bundle.Notes');
  });
  test('grouping labels', () {
    expect(groupingLabel(Grouping.project), '按项目');
  });
  test('open verbs by lamp', () {
    expect(openVerb(null), '打开');
    expect(openVerb(Lamp.notOpened), '打开');
    expect(openVerb(Lamp.disconnected), '重连');
    expect(openVerb(Lamp.active), '切到');
    expect(openVerb(Lamp.idle), '切到');
    expect(openVerb(Lamp.connecting), '切到');
  });

  test('desktop entry and its other screens', () {
    expect(isDesktopApp('desktop:'), isTrue);
    expect(isDesktopApp('desktop:42'), isTrue);
    expect(isDesktopApp('com.apple.Safari'), isFalse);
    expect(isDesktopScreen('desktop:'), isFalse);
    expect(isDesktopScreen('desktop:42'), isTrue);
    expect(isDesktopScreen('term:'), isFalse);
  });
}
