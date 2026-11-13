import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_choice.dart';
import 'package:rapp/ui/app_profile_store.dart';

RemoteWindow w(int id, {WindowKind kind = WindowKind.normal, int parent = 0, String? title}) => RemoteWindow(
      id: id,
      parent: parent,
      kind: kind,
      title: title ?? 'w$id',
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      titleBar: 28,
      resizable: true,
      focused: false,
      texture: id,
      visible: const Rect.fromLTWH(0, 0, 1, 1),
    );

const builtinJson =
    '{"version":1,"apps":[{"ids":["com.google.Chrome"],"name":"Google Chrome","stream":{"mode":"color16","density":"adaptive","fps":15}}]}';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('apps'));
  tearDown(() {
    Process.runSync('chmod', ['755', dir.path]);
    dir.deleteSync(recursive: true);
  });

  File f(String n) => File('${dir.path}/$n');
  void put(String s) => f('apps.json').writeAsStringSync(s);

  test('missing apps.json: empty, no problem; bad built-in JSON: no built-ins, no problem', () {
    final s = AppProfileStore.load(dir.path, '{not json');
    expect(s.mine, isEmpty);
    expect(s.builtin, isEmpty);
    expect(s.problem, isNull);
    expect(s.resolve('com.google.Chrome'), same(ResolvedProfile.generic));
  });

  test('a broken apps.json moves to apps.json.bad and reports it', () {
    put('{"version": 1, "apps": 3}');
    final s = AppProfileStore.load(dir.path, null);
    expect(s.problem, appsLoadProblem);
    expect(f('apps.json').existsSync(), isFalse);
    expect(f('apps.json.bad').readAsStringSync(), '{"version": 1, "apps": 3}');
  });

  test('rememberStream then load round-trips; the file has version 1 and only my fields', () {
    final s = AppProfileStore.load(dir.path, builtinJson);
    s.rememberStream('com.google.Chrome', 'Google Chrome', const StreamChoice('duocolor', 'adaptive', 5));
    final raw = jsonDecode(f('apps.json').readAsStringSync());
    expect(raw, {
      'version': 1,
      'apps': [
        {'ids': ['com.google.Chrome'], 'stream': {'mode': 'duocolor', 'density': 'adaptive', 'fps': 5}}
      ]
    });
    expect(AppProfileStore.load(dir.path, builtinJson).resolve('com.google.chrome').stream,
        const StreamChoice('duocolor', 'adaptive', 5));
    expect(f('apps.json.tmp').existsSync(), isFalse);
  });

  test('addRule goes first and copies built-in rules once; a new app gets its name', () {
    final s = AppProfileStore(dir.path);
    s.addRule('com.x', 'X', const WindowRule(title: 'a', action: RuleAction.hide));
    s.addRule('com.x', 'X', const WindowRule(title: 'b', action: RuleAction.noComposer));
    expect(s.mine.single.name, 'X');
    expect(s.mine.single.windows!.map((r) => r.title), ['b', 'a']);
  });

  test('addRule copies the built-in rules once', () {
    final s = AppProfileStore(dir.path, builtin: [
      AppProfile(ids: ['b'], name: 'B', windows: [const WindowRule(title: 'p', action: RuleAction.hide)])
    ]);
    s.addRule('b', 'B', const WindowRule(title: 'q', action: RuleAction.hide));
    expect(s.mine.single.name, isNull);
    expect(s.mine.single.windows!.map((r) => r.title), ['q', 'p']);
    expect(s.builtin.single.windows!.length, 1);
  });

  test('removeHideRule removes the first hide rule that matches, keeps the rest', () {
    final s = AppProfileStore(dir.path, mine: [
      AppProfile(ids: ['a'], windows: [
        const WindowRule(title: 'x*', action: RuleAction.noComposer),
        const WindowRule(title: 'x*', action: RuleAction.hide),
        const WindowRule(action: RuleAction.hide),
      ])
    ]);
    expect(s.removeHideRule('a', w(2, title: 'x1'), isMain: false), isTrue);
    expect(s.mine.single.windows!.length, 2);
    expect(s.mine.single.windows!.last, const WindowRule(action: RuleAction.hide));
    expect(s.removeHideRule('zzz', w(2), isMain: false), isFalse);
  });

  test('snapshot / restore undoes a change, on disk too', () {
    final s = AppProfileStore(dir.path);
    final before = s.snapshot();
    s.addRule('a', 'A', const WindowRule(action: RuleAction.hide));
    s.restore(before);
    expect(s.mine, isEmpty);
    expect(jsonDecode(f('apps.json').readAsStringSync())['apps'], isEmpty);
  });

  test('rows: built-in, changed, mine and a duplicate', () {
    final s = AppProfileStore(dir.path,
        builtin: [AppProfile(ids: ['b1'], name: 'B1', tested: false), AppProfile(ids: ['b2'], name: 'B2', tested: false)],
        mine: [AppProfile(ids: ['B2'], fps: 5), AppProfile(ids: ['m'], name: 'M'), AppProfile(ids: ['m'], name: 'M2')]);
    final rows = s.rows();
    expect(rows.map((r) => (r.name, r.source)), [
      ('B1', ProfileSource.builtin),
      ('B2', ProfileSource.changed),
      ('M', ProfileSource.mine),
      ('M2', ProfileSource.mine)
    ]);
    expect(rows[1].tested, isFalse);
    expect(rows[3].duplicateOf, 'M');
    expect(rows.map((r) => sourceLabel(r.source)).toSet(), {'内置', '内置 + 我改过', '我的'});
  });

  test('restoreBuiltin drops every profile of mine sharing an id', () {
    final b = AppProfile(ids: ['b', 'b.exe'], name: 'B');
    final s = AppProfileStore(dir.path, builtin: [b], mine: [AppProfile(ids: ['B.EXE'], fps: 1), AppProfile(ids: ['z'])]);
    s.restoreBuiltin(b);
    expect(s.mine.map((p) => p.ids.first), ['z']);
  });

  test('put replaces in place or appends; remove drops', () {
    final a = AppProfile(ids: ['a']), b = AppProfile(ids: ['b']);
    final s = AppProfileStore(dir.path, mine: [a]);
    s.put(b);
    expect(s.mine, [a, b]);
    final a2 = AppProfile(ids: ['a'], fps: 5);
    s.put(a2, replacing: a);
    expect(s.mine, [a2, b]);
    s.remove(b);
    expect(s.mine, [a2]);
  });

  test('a save that fails keeps the change in memory and reports it', () {
    Process.runSync('chmod', ['555', dir.path]);
    final s = AppProfileStore(dir.path);
    var told = 0;
    s.addListener(() => told++);
    s.addRule('a', 'A', const WindowRule(action: RuleAction.hide));
    expect(s.problem, appsSaveProblem);
    expect(s.mine.length, 1);
    expect(told, 1);
  });

  test('a later good save clears the save problem', () {
    Process.runSync('chmod', ['555', dir.path]);
    final s = AppProfileStore(dir.path);
    s.addRule('a', 'A', const WindowRule(action: RuleAction.hide));
    expect(s.problem, appsSaveProblem);
    Process.runSync('chmod', ['755', dir.path]);
    s.addRule('b', 'B', const WindowRule(action: RuleAction.hide));
    expect(s.problem, isNull);
  });
}
