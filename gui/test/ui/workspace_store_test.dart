import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/workspace_store.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ws'));
  tearDown(() {
    Process.runSync('chmod', ['755', dir.path]);
    dir.deleteSync(recursive: true);
  });

  File f([String n = 'workspace.json']) => File('${dir.path}/$n');
  void put(String s, [String n = 'workspace.json']) => f(n).writeAsStringSync(s);

  test('a missing file is empty with no problem', () {
    final r = loadWorkspace(dir.path);
    expect(r.problem, isNull);
    expect(r.workspace.favorites, isEmpty);
    expect(r.workspace.projects, isEmpty);
  });

  test('save then load round-trips the spec shape', () {
    final w = Workspace(
      favorites: [const AppRef('111', 'com.apple.calculator', 'Calculator')],
      projects: [
        Project('p1', '写周报', [Member(const AppRef('222', 'com.apple.Notes', 'Notes'), '整理 PR')]),
      ],
    );
    saveWorkspace(dir.path, w);
    final raw = jsonDecode(f().readAsStringSync()) as Map;
    expect(raw.keys.toSet(), {'version', 'favorites', 'projects'});
    expect(raw['version'], 1);
    expect((raw['favorites'] as List).single, {'device': '111', 'bundle': 'com.apple.calculator', 'name': 'Calculator'});
    expect((raw['projects'] as List).single, {
      'id': 'p1',
      'name': '写周报',
      'members': [
        {'device': '222', 'bundle': 'com.apple.Notes', 'name': 'Notes', 'task': '整理 PR'},
      ],
    });
    final back = loadWorkspace(dir.path).workspace;
    expect(back.projects.single.members.single.task, '整理 PR');
    expect(f('workspace.json.tmp').existsSync(), false);
  });

  test('a corrupt file starts empty and keeps .bad', () {
    put('{not json');
    final r = loadWorkspace(dir.path);
    expect(r.problem, loadProblem);
    expect(r.workspace.favorites, isEmpty);
    expect(r.workspace.projects, isEmpty);
    expect(f().existsSync(), false);
    expect(f('workspace.json.bad').readAsStringSync(), '{not json');
  });

  test('an unknown version is treated as corrupt', () {
    put('{"version":2,"favorites":[],"projects":[]}');
    expect(loadWorkspace(dir.path).problem, loadProblem);
    expect(f('workspace.json.bad').existsSync(), true);
  });

  test('wrong shapes are corrupt', () {
    for (final s in [
      '[]',
      '{"version":1,"favorites":{}}',
      '{"version":1,"projects":[{"name":"x","members":[]}]}',
      '{"version":1,"favorites":[{"device":"111"}]}',
    ]) {
      put(s);
      expect(loadWorkspace(dir.path).problem, loadProblem, reason: s);
    }
  });

  test('missing name and task get defaults', () {
    put('{"version":1,"projects":[{"id":"p","name":"n","members":[{"device":"1","bundle":"b.x"}]}]}');
    final r = loadWorkspace(dir.path);
    expect(r.problem, isNull);
    final m = r.workspace.projects.single.members.single;
    expect(m.app.name, 'b.x');
    expect(m.task, '');
    expect(r.workspace.favorites, isEmpty);
    put('{"version":1,"favorites":[{"device":"1","bundle":"b.x"}]}');
    final r2 = loadWorkspace(dir.path);
    expect(r2.problem, isNull);
    expect(r2.workspace.projects, isEmpty);
    expect(r2.workspace.favorites.single.name, 'b.x');
  });

  test('duplicates load once', () {
    put(jsonEncode({
      'version': 1,
      'favorites': [
        {'device': '1', 'bundle': 'a', 'name': 'first'},
        {'device': '1', 'bundle': 'a', 'name': 'second'},
      ],
      'projects': [
        {
          'id': 'p',
          'name': 'one',
          'members': [
            {'device': '1', 'bundle': 'a', 'name': 'A', 'task': 't1'},
            {'device': '1', 'bundle': 'a', 'name': 'A', 'task': 't2'},
          ],
        },
        {'id': 'p', 'name': 'two', 'members': []},
      ],
    }));
    final w = loadWorkspace(dir.path).workspace;
    expect(w.favorites.single.name, 'first');
    expect(w.projects.single.name, 'one');
    expect(w.projects.single.members.single.task, 't1');
  });

  test('names and tasks load as one line', () {
    put(r'{"version":1,"favorites":[{"device":"1","bundle":"b","name":"a\nb "}]}');
    expect(loadWorkspace(dir.path).workspace.favorites.single.name, 'a b');
  });

  test('an existing .bad is replaced', () {
    put('old', 'workspace.json.bad');
    put('new');
    loadWorkspace(dir.path);
    expect(f('workspace.json.bad').readAsStringSync(), 'new');
  });

  test('a failed write leaves the old file whole', () {
    saveWorkspace(dir.path, Workspace(favorites: [const AppRef('1', 'a', 'A')]));
    Directory('${dir.path}/workspace.json.tmp').createSync();
    expect(
      () => saveWorkspace(dir.path, Workspace(favorites: [const AppRef('2', 'b', 'B')])),
      throwsA(isA<FileSystemException>()),
    );
    final r = loadWorkspace(dir.path);
    expect(r.problem, isNull);
    expect(r.workspace.favorites.single.device, '1');
  });

  test('a save after a bad load leaves .bad alone', () {
    put('{x');
    loadWorkspace(dir.path);
    saveWorkspace(dir.path, Workspace());
    expect(f('workspace.json.bad').readAsStringSync(), '{x');
    final r = loadWorkspace(dir.path);
    expect(r.problem, isNull);
    expect(r.workspace.favorites, isEmpty);
  });

  test('project ids are uuid v4 and differ', () {
    final re = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    final ids = {for (var i = 0; i < 100; i++) newProjectId()};
    expect(ids, hasLength(100));
    expect(ids.every(re.hasMatch), true);
  });

  test('oneLine folds newlines', () {
    expect(oneLine(' a\r\nb\n '), 'a  b');
  });
}
