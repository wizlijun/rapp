import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/history/draft_store.dart';

void main() {
  late Directory tmp;
  late DraftStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('drafts');
    store = DraftStore(() => '${tmp.path}/drafts');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a draft round-trips with mode 0600', () async {
    final d = DraftFile(key: 'k1', text: 'hi 你好', pending: ['a', 'b'], meta: {'app': 'x'});
    await store.save(d);
    final got = store.load('k1')!;
    expect(got.toJson(), d.toJson());
    if (Platform.isMacOS || Platform.isLinux) {
      expect(File(store.pathFor('k1')).statSync().mode & 0x1ff, 0x180);
    }
    expect(Directory('${tmp.path}/drafts').listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
  });

  test('a key with / and : makes one flat file name', () async {
    await store.save(DraftFile(key: 'h1/term:tmux:dev', text: 'x'));
    final p = store.pathFor('h1/term:tmux:dev');
    expect(p.substring('${tmp.path}/drafts/'.length), isNot(contains('/')));
    expect(p, '${tmp.path}/drafts/aDEvdGVybTp0bXV4OmRldg.json');
    expect(Directory('${tmp.path}/drafts').listSync().length, 1);
    expect(store.load('h1/term:tmux:dev')!.text, 'x');
  });

  test('an empty draft with nothing pending deletes the file', () async {
    await store.save(DraftFile(key: 'k', text: 'x'));
    expect(File(store.pathFor('k')).existsSync(), isTrue);
    await store.save(DraftFile(key: 'k'));
    expect(File(store.pathFor('k')).existsSync(), isFalse);
    expect(store.load('k'), isNull);
  });

  test('writes to one key apply in order', () async {
    final fs = [for (var i = 0; i < 10; i++) store.save(DraftFile(key: 'k', text: '$i'))];
    await Future.wait(fs);
    expect(store.load('k')!.text, '9');
  });

  test('scan skips a broken file', () async {
    await store.save(DraftFile(key: 'good', text: 'x'));
    final bad = File('${tmp.path}/drafts/bad.json')..writeAsStringSync('{');
    final r = store.scan();
    expect(r.length, 1);
    expect(r.single.$1.key, 'good');
    expect(bad.existsSync(), isTrue);
  });
}
