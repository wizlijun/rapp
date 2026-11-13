import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/data_dir.dart';

void main() {
  late Directory tmp;
  late String root, legacy;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rapp_dd');
    root = '${tmp.path}/root';
    legacy = '${tmp.path}/legacy';
    Directory(legacy).createSync(recursive: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String read(String p) => File(p).readAsStringSync();
  void put(String p, String s) {
    File(p).parent.createSync(recursive: true);
    File(p).writeAsStringSync(s);
  }

  String mode(String p) {
    return Process.runSync('stat', ['-f', '%Lp', p]).stdout.toString().trim();
  }

  void oldConfig(String d) {
    put('$d/service.json', '{"id":"123456789","secret":"s"}');
    for (final f in [
      'hosts.json',
      'update.json',
      'update-applied.json',
      'workspace.json',
      'apps.json',
      'gui.json',
      'permission-guide-shown',
      'ipc.token',
    ]) {
      put('$d/$f', 'old $f');
    }
    put('$d/previous/rapp.app/x', 'x');
  }

  test('fresh root gets the layout', () {
    expect(prepareDataDir(root, legacy), isFalse);
    for (final d in ['shared', 'devices', 'agent', 'clipboard', 'files/transfers', 'files/clipboard', 'local']) {
      expect(Directory('$root/$d').existsSync(), isTrue, reason: d);
    }
    expect(read('$root/README.md').startsWith(readmeMarker), isTrue);
    expect(read('$root/.gitignore'), dataGitignore);
    expect(read('$root/agent/README.md'), agentReadme);
    expect(mode('$root/local'), '700');
  });

  test('existing texts are kept', () {
    put('$root/README.md', 'mine');
    put('$root/agent/README.md', 'mine too');
    prepareDataDir(root, legacy);
    expect(read('$root/README.md'), 'mine');
    expect(read('$root/agent/README.md'), 'mine too');
  });

  test('migrates by the table and copies only', () {
    oldConfig(legacy);
    expect(prepareDataDir(root, legacy), isTrue);
    for (final (old, nu) in [
      ('service.json', 'local/service.json'),
      ('hosts.json', 'local/hosts.json'),
      ('update.json', 'local/update.json'),
      ('update-applied.json', 'local/update-applied.json'),
      ('permission-guide-shown', 'local/permission-guide-shown'),
      ('workspace.json', 'shared/workspace.json'),
      ('apps.json', 'shared/apps.json'),
      ('gui.json', 'devices/123456789/gui.json'),
    ]) {
      expect(read('$root/$nu'), read('$legacy/$old'), reason: nu);
      expect(File('$legacy/$old').existsSync(), isTrue, reason: 'old $old kept');
    }
    expect(File('$root/local/ipc.token').existsSync(), isFalse);
    expect(Directory('$root/local/previous').existsSync(), isFalse);
    expect(read('$root/local/migrated-from').trim(), legacy);
    expect(mode('$root/local/service.json'), '600');
    expect(mode('$root/local/hosts.json'), '600');
  });

  test('second run is a no-op', () {
    oldConfig(legacy);
    expect(prepareDataDir(root, legacy), isTrue);
    put('$root/shared/workspace.json', 'edited');
    expect(prepareDataDir(root, legacy), isFalse);
    expect(read('$root/shared/workspace.json'), 'edited');
  });

  test('never overwrites an existing file', () {
    oldConfig(legacy);
    put('$root/local/hosts.json', 'local one');
    expect(prepareDataDir(root, legacy), isTrue);
    expect(read('$root/local/hosts.json'), 'local one');
    expect(read('$root/local/service.json'), read('$legacy/service.json'));
  });

  test('rapp home flat layout migrates into local', () {
    final home = '${tmp.path}/home';
    oldConfig(home);
    expect(prepareDataDir(home, home), isTrue);
    expect(read('$home/local/service.json'), read('$home/service.json'));
    expect(read('$home/shared/apps.json'), 'old apps.json');
  });

  test('no legacy service.json no migration', () {
    put('$legacy/workspace.json', 'w');
    expect(prepareDataDir(root, legacy), isFalse);
    expect(File('$root/shared/workspace.json').existsSync(), isFalse);
  });

  test('a failed copy leaves no service.json', () {
    oldConfig(legacy);
    final hosts = '$legacy/hosts.json';
    Process.runSync('chmod', ['000', hosts]);
    addTearDown(() => Process.runSync('chmod', ['600', hosts]));
    try {
      File(hosts).readAsBytesSync();
      return; // running as root; cannot test
    } on FileSystemException {
      // expected
    }
    expect(() => prepareDataDir(root, legacy), throwsA(isA<FileSystemException>()));
    expect(File('$root/local/service.json').existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test('templates match the Rust copies word for word', () {
    expect(dataReadme, File('../rust/net/src/datadir/README.md').readAsStringSync());
    expect(agentReadme, File('../rust/net/src/datadir/agent-README.md').readAsStringSync());
    expect(dataGitignore, File('../rust/net/src/datadir/gitignore').readAsStringSync());
    expect(dataReadme.split('\n').first, readmeMarker);
  });

  test('isRappDataDir: only a README whose first line is the marker', () {
    expect(isRappDataDir(root), isFalse);
    put('$root/README.md', '# 别的\n');
    expect(isRappDataDir(root), isFalse);
    put('$root/README.md', dataReadme);
    expect(isRappDataDir(root), isTrue);
  });
}
