import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/history/input_log.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('inlog'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('append writes one line per record into the day file', () async {
    final log = InputLog(() => '${tmp.path}/inputs');
    final at = DateTime(2026, 11, 14, 21, 37);
    await log.append({'id': 'a', 'text': '你好'}, at);
    await log.append({'id': 'b', 'text': 'x\ny'}, at);
    final raw = File('${tmp.path}/inputs/2026-11-14.jsonl').readAsStringSync();
    expect(raw, contains('你好'));
    final lines = raw.trimRight().split('\n');
    expect(lines.map(jsonDecode).toList(), [
      {'id': 'a', 'text': '你好'},
      {'id': 'b', 'text': 'x\ny'},
    ]);
  });

  test('an append after a torn last line starts on a new line', () async {
    final log = InputLog(() => tmp.path);
    final f = File('${tmp.path}/2026-11-14.jsonl')..writeAsStringSync('{"id":"a"}\n{"id":"b","te');
    await log.append({'id': 'c'}, DateTime(2026, 11, 14));
    await log.append({'id': 'd'}, DateTime(2026, 11, 14));
    expect(f.readAsStringSync(), '{"id":"a"}\n{"id":"b","te\n{"id":"c"}\n{"id":"d"}\n');
  });

  test('appends keep their order', () async {
    final log = InputLog(() => tmp.path);
    final at = DateTime(2026, 11, 14);
    final fs = [for (var i = 0; i < 20; i++) log.append({'i': i}, at)];
    await Future.wait(fs);
    final got = File('${tmp.path}/2026-11-14.jsonl').readAsLinesSync().map((l) => jsonDecode(l)['i']).toList();
    expect(got, List.generate(20, (i) => i));
  });

  test('a write that cannot happen fails the future', () async {
    final f = File('${tmp.path}/plain')..writeAsStringSync('x');
    final log = InputLog(() => f.path);
    await expectLater(log.append({'a': 1}, DateTime(2026, 11, 14)), throwsA(isA<FileSystemException>()));
    // a later append is not blocked by the failure
    final ok = InputLog(() => '${tmp.path}/d');
    await ok.append({'a': 1}, DateTime(2026, 11, 14));
  });
}
