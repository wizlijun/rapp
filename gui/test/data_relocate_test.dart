import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/data_dir.dart';
import 'package:rapp/data_relocate.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rapp-relocate'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const nested = '新位置不能在当前数据目录里面，也不能包着它';

  test('refuses a folder inside or around the current root', () {
    expect(planRelocation('/t/rapp', '/t/rapp').error, '已经是这个位置');
    expect(planRelocation('/t/rapp', '/t/rapp/').error, '已经是这个位置');
    expect(planRelocation('/t/rapp', '/t/rapp/sub').error, nested);
    expect(planRelocation('/t/rapp', '/t').error, nested);
    expect(planRelocation('/t/rapp', '/t/rapp2').error, isNull);
  });

  test('dot-dot paths are resolved before comparing', () {
    expect(planRelocation('/t/rapp', '/t/x/../rapp').error, '已经是这个位置');
    expect(planRelocation('/t/rapp', '/t/rapp/sub/../..').error, nested);
    expect(planRelocation('/t/rapp', '/t/rapp/./sub').error, nested);
  }, skip: Platform.isWindows);

  test('refuses a non-empty folder that is not rapp\'s', () {
    final to = Directory('${tmp.path}/to')..createSync();
    File('${to.path}/x.txt').writeAsStringSync('x');
    expect(planRelocation('${tmp.path}/from', to.path).error, '这个文件夹里已经有别的东西，选一个空文件夹');
  });

  test('copy: missing or empty folder; keeps modes and .git; old root untouched', () async {
    final from = '${tmp.path}/from';
    prepareDataDir(from, '${tmp.path}/none');
    File('$from/local/service.json').writeAsStringSync('{}');
    Process.runSync('chmod', ['600', '$from/local/service.json']);
    Directory('$from/.git').createSync();
    File('$from/.git/HEAD').writeAsStringSync('ref');
    File('$from/files/transfers/a.bin').writeAsStringSync('a');
    final pointer = '${tmp.path}/cfg/data-root';
    for (final mk in [false, true]) {
      final to = '${tmp.path}/to$mk';
      if (mk) Directory(to).createSync();
      final plan = planRelocation(from, to);
      expect(plan.kind, RelocateKind.copy);
      expect(await applyRelocation(from: from, to: to, kind: plan.kind!, pointer: pointer, isDefault: false), isNull);
      expect(File('$to/.git/HEAD').existsSync(), isTrue);
      expect(File('$to/files/transfers/a.bin').existsSync(), isTrue);
      expect(File('$to/README.md').existsSync(), isTrue);
      expect(File('$to/local/service.json').statSync().mode & 0x1ff, 384);
      expect(File('$from/local/service.json').existsSync(), isTrue);
      expect(File('$from/.git/HEAD').existsSync(), isTrue);
      expect(File(pointer).readAsStringSync(), '$to\n');
    }
  });

  test('adopt: a folder with rapp\'s README is used as is', () async {
    final from = '${tmp.path}/from';
    prepareDataDir(from, '${tmp.path}/none');
    final to = '${tmp.path}/to';
    prepareDataDir(to, '${tmp.path}/none');
    File('$to/shared/workspace.json').writeAsStringSync('theirs');
    File('$from/shared/mine.txt').writeAsStringSync('m');
    final plan = planRelocation(from, to);
    expect(plan.kind, RelocateKind.adopt);
    final pointer = '${tmp.path}/cfg/data-root';
    expect(await applyRelocation(from: from, to: to, kind: plan.kind!, pointer: pointer, isDefault: false), isNull);
    expect(File('$to/shared/workspace.json').readAsStringSync(), 'theirs');
    expect(File('$to/shared/mine.txt').existsSync(), isFalse);
    expect(File(pointer).readAsStringSync(), '$to\n');
  });

  test('back to default deletes the pointer', () async {
    final pointer = File('${tmp.path}/cfg/data-root')..createSync(recursive: true);
    pointer.writeAsStringSync('/x\n');
    final to = '${tmp.path}/to';
    prepareDataDir(to, '${tmp.path}/none');
    expect(await applyRelocation(from: '${tmp.path}/from', to: to, kind: RelocateKind.adopt, pointer: pointer.path, isDefault: true), isNull);
    expect(pointer.existsSync(), isFalse);
    // A missing pointer is fine too.
    expect(await applyRelocation(from: '${tmp.path}/from', to: to, kind: RelocateKind.adopt, pointer: pointer.path, isDefault: true), isNull);
  });

  test('a failed copy leaves the pointer alone', () async {
    final pointer = '${tmp.path}/cfg/data-root';
    final r = await applyRelocation(
      from: '${tmp.path}/from',
      to: '${tmp.path}/to',
      kind: RelocateKind.copy,
      pointer: pointer,
      isDefault: false,
      run: (_, a) async => ProcessResult(0, 1, '', 'cp: no space\nmore'),
    );
    expect(r, '复制没成功：cp: no space');
    expect(File(pointer).existsSync(), isFalse);
  });
}
