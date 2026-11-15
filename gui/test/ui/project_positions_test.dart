import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/project_positions.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rapp_positions'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('round-trip', () {
    final a = ProjectPositions();
    a.of('p')
      ..last = '111/a'
      ..leftAt = DateTime.utc(2026, 11, 14, 1, 2, 3);
    a.save(tmp.path);
    final b = ProjectPositions.load(tmp.path);
    expect(b.byProject['p']!.last, '111/a');
    expect(b.byProject['p']!.leftAt, DateTime.utc(2026, 11, 14, 1, 2, 3));
    expect(
      File('${tmp.path}/$positionsFile').readAsStringSync(),
      contains('"left_at":"2026-11-14T01:02:03.000Z"'),
    );
  });

  test('save writes the documented shape under version 1', () {
    final a = ProjectPositions({
      'p': ProjectPosition(last: '111/com.apple.Safari', leftAt: DateTime.utc(2026, 11, 14, 1, 2, 3)),
    });
    a.save(tmp.path);
    expect(
      File('${tmp.path}/$positionsFile').readAsStringSync(),
      '{"version":1,"projects":{"p":{"last":"111/com.apple.Safari","left_at":"2026-11-14T01:02:03.000Z"}}}',
    );
  });

  test('missing or corrupt file is empty; a malformed entry is skipped', () {
    expect(ProjectPositions.load(tmp.path).byProject, isEmpty);
    File('${tmp.path}/$positionsFile').writeAsStringSync('{');
    expect(ProjectPositions.load(tmp.path).byProject, isEmpty);
    File('${tmp.path}/$positionsFile').writeAsStringSync(
      '{"version":1,"projects":{"p":{"last":7},"q":{"last":"1/a","left_at":"nope"},"r":{"last":"2/b"}}}',
    );
    final b = ProjectPositions.load(tmp.path);
    expect(b.byProject.keys.toSet(), {'q', 'r'});
    expect(b.byProject['q']!.last, '1/a');
    expect(b.byProject['q']!.leftAt, isNull);
    expect(b.byProject['r']!.last, '2/b');
  });

  test('of creates an empty position once and returns it after', () {
    final p = ProjectPositions();
    final first = p.of('p');
    expect(first.last, isNull);
    expect(first.leftAt, isNull);
    first.last = 'x';
    expect(p.of('p').last, 'x');
  });

  test('dropExcept forgets deleted projects', () {
    final p = ProjectPositions({'p': ProjectPosition(last: 'x'), 'gone': ProjectPosition(last: 'y')});
    p.dropExcept({'p'});
    expect(p.byProject.keys, ['p']);
  });

  test('save into a missing dir creates it', () {
    final d = '${tmp.path}/a/b';
    ProjectPositions({'p': ProjectPosition(last: '1/a')}).save(d);
    expect(ProjectPositions.load(d).byProject['p']!.last, '1/a');
  });

  test('save into a read-only dir throws FileSystemException', () {
    Process.runSync('chmod', ['500', tmp.path]);
    expect(
      () => ProjectPositions({'p': ProjectPosition(last: '1/a')}).save(tmp.path),
      throwsA(isA<FileSystemException>()),
    );
    Process.runSync('chmod', ['700', tmp.path]);
  });
}
