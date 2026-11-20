import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/history/input_history.dart';
import 'package:rapp/history/input_log.dart';
import 'package:rapp/paths.dart';

/// A record as the recorder writes it (input_recorder.dart `_common`).
Map<String, Object?> rec(String id, String ts, String text,
        {String from = 'dev1', String session = 'h1/com.apple.Terminal', String kind = 'sent'}) =>
    {
      'v': 1,
      'id': id,
      'ts': ts,
      'kind': kind,
      'from': {'id': from, 'name': 'name-$from'},
      'host': {'id': session.split('/').first, 'name': 'mac'},
      'app': {'id': 'com.apple.Terminal', 'name': '终端'},
      'session': session,
      'run': 'r1',
      'window': {'id': 7, 'title': 'agent — zsh'},
      'projects': <String>[],
      'text': text,
      'blocks': const <Object>[],
      'source': 'typed',
    };

void main() {
  late Directory tmp;
  late DataDir data;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('input_history_test');
    data = DataDir(tmp.path);
    Directory(data.localDir).createSync(recursive: true);
    File('${data.localDir}/service.json').writeAsStringSync('{"id":"dev1"}');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  File day(String dev, String d, List<Object> lines) {
    final f = File('${data.inputsDir(dev)}/$d.jsonl');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(lines.map((l) => l is String ? '$l\n' : '${jsonEncode(l)}\n').join());
    return f;
  }

  InputHistory history() => InputHistory(data: () => data);

  test('records from every device merge newest first', () async {
    day('dev1', '2026-11-14', [
      rec('01A', '2026-11-14T10:00:00+09:00', 'one'),
      rec('01C', '2026-11-14T12:00:00+09:00', 'three'),
    ]);
    day('dev2', '2026-11-14', [
      rec('01B', '2026-11-14T11:00:00+09:00', 'two', from: 'dev2'),
      rec('01D', '2026-11-14T13:00:00+09:00', 'four', from: 'dev2'),
    ]);
    final h = history();
    await h.refresh();
    final all = h.forSession('h1/com.apple.Terminal');
    expect(all.map((e) => e.text), ['four', 'three', 'two', 'one']);
    final four = all.first;
    expect(four.id, '01D');
    expect(four.deviceId, 'dev2');
    expect(four.mine, isFalse);
    expect(all[1].mine, isTrue);
    expect(four.kind, 'sent');
    expect(four.hostId, 'h1');
    expect(four.hostName, 'mac');
    expect(four.appName, '终端');
    expect(four.windowTitle, 'agent — zsh');
    expect(four.day, '2026-11-14');
    expect(four.ts, DateTime.parse('2026-11-14T13:00:00+09:00'));
    expect(four.raw['run'], 'r1');
  });

  test('a broken line is skipped', () async {
    day('dev1', '2026-11-14', [
      rec('01A', '2026-11-14T10:00:00+09:00', 'one'),
      '{"v":1,',
      'not json',
      {'v': 1, 'id': '01X'}, // no ts, text or session
      rec('01C', '2026-11-14T12:00:00+09:00', 'three'),
    ]);
    final h = history();
    await h.refresh();
    expect(h.forSession('h1/com.apple.Terminal').map((e) => e.text), ['three', 'one']);
  });

  test('a line with malformed UTF-8 is skipped, the rest of the file is read', () async {
    final f = day('dev1', '2026-11-14', [rec('01A', '2026-11-14T10:00:00+09:00', 'one')]);
    f.writeAsBytesSync([
      ...f.readAsBytesSync(),
      ...utf8.encode('{"v":1,"id":"01X","text":"'),
      0xE4, 0xBD, // a character cut short
      0x0A,
      ...utf8.encode('${jsonEncode(rec('01C', '2026-11-14T12:00:00+09:00', 'three'))}\n'),
    ]);
    final h = history();
    await h.refresh();
    expect(h.forSession('h1/com.apple.Terminal').map((e) => e.text), ['three', 'one']);
  });

  test('only changed files are read again', () async {
    final a = day('dev1', '2026-11-14', [rec('01A', '2026-11-14T10:00:00+09:00', 'aaa')]);
    final b = day('dev2', '2026-11-14', [rec('01B', '2026-11-14T11:00:00+09:00', 'bbb', from: 'dev2')]);
    final aTime = DateTime(2026, 11, 14, 12);
    a.setLastModifiedSync(aTime);
    final h = history();
    var notified = 0;
    h.addListener(() => notified++);
    await h.refresh();
    expect(notified, 1);

    // Same length, same modification time: not read again, so the old text stays.
    a.writeAsStringSync('${jsonEncode(rec('01A', '2026-11-14T10:00:00+09:00', 'zzz'))}\n');
    a.setLastModifiedSync(aTime);
    // A longer file is read again.
    b.writeAsStringSync('${jsonEncode(rec('01B', '2026-11-14T11:00:00+09:00', 'bbb', from: 'dev2'))}\n'
        '${jsonEncode(rec('01E', '2026-11-14T14:00:00+09:00', 'eee', from: 'dev2'))}\n');
    await h.refresh();
    expect(h.forSession('h1/com.apple.Terminal').map((e) => e.text), ['eee', 'bbb', 'aaa']);
    expect(notified, 2);

    // Nothing changed: no notification. A file that went takes its records with it.
    await h.refresh();
    expect(notified, 2);
    b.deleteSync();
    await h.refresh();
    expect(h.forSession('h1/com.apple.Terminal').map((e) => e.text), ['aaa']);
  });

  test('the same text twice in a row counts once for a session', () async {
    day('dev1', '2026-11-14', [
      rec('01A', '2026-11-14T10:00:00+09:00', 'again'),
      rec('01B', '2026-11-14T10:01:00+09:00', 'again'),
      rec('01C', '2026-11-14T10:02:00+09:00', 'other'),
      rec('01D', '2026-11-14T10:03:00+09:00', 'again'),
      rec('01E', '2026-11-14T10:04:00+09:00', 'elsewhere', session: 'h2/x'),
      rec('01F', '2026-11-14T10:05:00+09:00', ''), // a send of blocks only: nothing to bring back
    ]);
    final h = history();
    await h.refresh();
    final s = h.forSession('h1/com.apple.Terminal');
    expect(s.map((e) => e.text), ['again', 'other', 'again']);
    expect(s.map((e) => e.id), ['01D', '01C', '01B']);
    expect(h.forSession('h2/x').map((e) => e.text), ['elsewhere']);
    expect(h.forSession('nope'), isEmpty);
  });

  test('add takes a written record once, also when its file is read later', () async {
    final h = history();
    await h.refresh();
    var notified = 0;
    h.addListener(() => notified++);
    final r = rec('01A', '2026-11-14T10:00:00+09:00', 'fresh');
    h.add(r);
    h.add({'v': 1, 'id': 'broken'}); // skipped
    expect(notified, 1);
    expect(h.forSession('h1/com.apple.Terminal').single.text, 'fresh');
    expect(h.forSession('h1/com.apple.Terminal').single.day, '2026-11-14');
    day('dev1', '2026-11-14', [r]);
    await h.refresh();
    expect(h.forSession('h1/com.apple.Terminal').map((e) => e.id), ['01A']);
  });

  test('search finds text, narrowed to a session or a host', () async {
    day('dev1', '2026-11-14', [
      rec('01A', '2026-11-14T10:00:00+09:00', 'Build the thing'),
      rec('01B', '2026-11-14T11:00:00+09:00', 'build again', session: 'h2/x'),
      rec('01C', '2026-11-14T12:00:00+09:00', 'other'),
    ]);
    final h = history();
    await h.refresh();
    expect(h.search('BUILD').map((e) => e.id), ['01B', '01A']);
    expect(h.search('build', session: 'h1/com.apple.Terminal').map((e) => e.id), ['01A']);
    expect(h.search('build', host: 'h2').map((e) => e.id), ['01B']);
    expect(h.search('').length, 3);
  });

  test('removing rewrites the day file without that line only', () async {
    final f = day('dev1', '2026-11-14', [
      rec('01A', '2026-11-14T10:00:00+09:00', 'one 一'),
      rec('01B', '2026-11-14T11:00:00+09:00', 'two'),
      rec('01C', '2026-11-14T12:00:00+09:00', 'three'),
    ]);
    final lines = const LineSplitter().convert(utf8.decode(f.readAsBytesSync()));
    final h = history();
    await h.refresh();
    h.add(rec('01B', '2026-11-14T11:00:00+09:00', 'two')); // came through add too
    final two = h.forSession('h1/com.apple.Terminal').firstWhere((e) => e.id == '01B');
    await h.remove(two);
    expect(f.readAsBytesSync(), utf8.encode('${lines[0]}\n${lines[2]}\n'));
    expect(h.search('').map((e) => e.id), ['01C', '01A']);
    expect(File('${f.path}.tmp').existsSync(), isFalse);
    await h.refresh(); // the new length and time make it read again: still gone
    expect(h.search('').map((e) => e.id), ['01C', '01A']);
    // Another device's record is left alone.
    day('dev2', '2026-11-14', [rec('02A', '2026-11-14T10:00:00+09:00', 'theirs', from: 'dev2')]);
    await h.refresh();
    await h.remove(h.search('theirs').single);
    expect(h.search('theirs'), hasLength(1));
  });

  test('a removal runs behind the appends already asked for on that file', () async {
    final f = day('dev1', '2026-11-14', [
      rec('01A', '2026-11-14T10:00:00', 'one'),
      rec('01B', '2026-11-14T11:00:00', 'two'),
    ]);
    final log = InputLog(() => data.inputsDir('dev1'));
    final h = history();
    await h.refresh();
    final two = h.search('two').single;
    final at = DateTime(2026, 11, 14, 12);
    final c = rec('01C', '2026-11-14T12:00:00', 'three');
    final d = rec('01D', '2026-11-14T12:01:00', 'four');
    final appends = [log.append(c, at), log.append(d, at)];
    h.add(d);
    final removals = [h.remove(two), h.remove(h.search('four').single)]; // 01D's append may not have landed
    await Future.wait([...appends, ...removals]);
    final ids = f.readAsLinesSync().map((l) => (jsonDecode(l) as Map)['id']).toList();
    expect(ids, ['01A', '01C']);
    await h.refresh();
    expect(h.search('').map((e) => e.id), ['01C', '01A']);
  });

  test('a missing devices dir is an empty history', () async {
    final h = history();
    await h.refresh();
    expect(h.forSession('h1/com.apple.Terminal'), isEmpty);
  });

  test('remember: this run\'s sends come back for up, merged with the record by time, never in search', () async {
    day('dev1', '2026-11-14', [rec('01A', '2026-11-14T10:00:00+09:00', 'on disk')]);
    final h = history();
    await h.refresh();
    var notified = 0;
    h.addListener(() => notified++);
    h.remember('h1/com.apple.Terminal', 'typed now', DateTime.parse('2026-11-14T10:05:00+09:00'));
    h.remember('h1/com.apple.Terminal', '', DateTime.parse('2026-11-14T10:06:00+09:00')); // nothing to recall
    h.remember('h2/x', 'elsewhere', DateTime.parse('2026-11-14T10:07:00+09:00'));
    expect(notified, 2);
    expect(h.forSession('h1/com.apple.Terminal').map((e) => e.text), ['typed now', 'on disk']);
    expect(h.search(''), hasLength(1));
    // The record of the same send lands a moment later: one entry, not two.
    h.add(rec('01Z', '2026-11-14T10:05:01+09:00', 'typed now'));
    expect(h.forSession('h1/com.apple.Terminal').map((e) => e.text), ['typed now', 'on disk']);
    // Taken out of the record: up stops bringing it back.
    await h.remove(h.search('typed now').single);
    expect(h.forSession('h1/com.apple.Terminal').map((e) => e.text), ['on disk']);
  });

  test('forSession prefix: one host\'s terminals share their history', () async {
    day('dev1', '2026-11-14', [
      rec('01A', '2026-11-14T10:00:00+09:00', 'ls', session: 'h1/term:pty:a'),
      rec('01B', '2026-11-14T10:01:00+09:00', 'pwd', session: 'h1/term:pty:b'),
      rec('01C', '2026-11-14T10:02:00+09:00', 'mail', session: 'h1/com.apple.Mail'),
      rec('01D', '2026-11-14T10:03:00+09:00', 'other host', session: 'h2/term:pty:a'),
    ]);
    final h = history();
    await h.refresh();
    h.remember('h1/term:pty:c', 'git status', DateTime.parse('2026-11-14T10:04:00+09:00'));
    expect(h.forSession('h1/term:', prefix: true).map((e) => e.text), ['git status', 'pwd', 'ls']);
    expect(h.forSession('h1/term:pty:a').map((e) => e.text), ['ls']);
  });
}
