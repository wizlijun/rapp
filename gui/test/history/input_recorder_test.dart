import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/composer_model.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/history/draft_store.dart';
import 'package:rapp/history/input_recorder.dart';
import 'package:rapp/paths.dart';

import '../fakes.dart';

const title = 'agent — zsh';

void main() {
  late Directory tmp;
  late DataDir data;
  late List<String> logs;
  late bool enabled;
  late FakeSessionPort port;
  late Set<String> appsOff;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('input_recorder_test');
    data = DataDir(tmp.path);
    Directory(data.localDir).createSync(recursive: true);
    File('${data.localDir}/service.json').writeAsStringSync('{"id":"dev1"}');
    Directory(data.deviceDir('dev1')).createSync(recursive: true);
    File('${data.deviceDir('dev1')}/device.json').writeAsStringSync('{"name":"bruce-tablet"}');
    logs = [];
    enabled = true;
    appsOff = {};
    port = FakeSessionPort();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  InputRecorder recorder() => InputRecorder(
      data: () => data, enabled: () => enabled, recordsApp: (a) => !appsOff.contains(a), log: logs.add);
  DraftStore drafts() => DraftStore(() => data.draftsDir);

  RemoteSession session(int sid, String app, {AfterSend after = AfterSend.none, bool record = true}) =>
      RemoteSession(sid, 'App $app', appId: app)..setProfile(ResolvedProfile(afterSend: after, recordInput: record));

  SessionMeta meta(String host, String app, {String run = 'run1'}) => SessionMeta(
      key: '$host/$app',
      hostId: host,
      hostName: 'host-$host',
      appId: app,
      appName: 'App $app',
      run: run,
      windowId: 7,
      windowTitle: title,
      projects: ['rapp']);

  // What the writing panel does on a send: submit, then hand the pieces to the port.
  Future<Outgoing?> send(RemoteSession rs, String text, {List<BlockChip> blocks = const []}) async {
    rs.composer.setDraft(text);
    rs.composer.apply(PasteResult(blocks: blocks)); // after the text
    final r = await rs.composer.submit();
    if (r is SubmitPieces) port.composerSend(rs.sid, r.pieces);
    return rs.composer.inFlight;
  }

  List<Map<String, Object?>> lines() {
    final d = Directory(data.inputsDir('dev1'));
    if (!d.existsSync()) return [];
    return [
      for (final f in d.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path)))
        for (final l in f.readAsLinesSync())
          if (l.isNotEmpty) (jsonDecode(l) as Map).cast<String, Object?>(),
    ];
  }

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));

  test('secure drafts and pending sends never reach disk, even when ACK arrives after blur', () async {
    final rec = recorder();
    final rs = session(1, 'com.a')..secureFocus = true;
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    rs.composer.setDraft('synthetic private draft');
    await settle();
    expect(drafts().load('h1/com.a'), isNull);
    await send(rs, 'synthetic private send', blocks: const [
      BlockChip(1, 'private block label', kind: 'text', text: 'synthetic private block'),
    ]);
    await settle();
    expect(drafts().load('h1/com.a'), isNull);
    rs.secureFocus = false;
    rs.composer.done(2, null);
    await settle();
    expect(lines(), isEmpty);
    expect(drafts().load('h1/com.a'), isNull);
    await send(rs, 'ordinary input');
    rs.composer.done(1, null);
    await until(() => lines().isNotEmpty);
    expect(lines().single['text'], 'ordinary input');
  });

  test('secure draft remains private after blur and session end, also with history off', () async {
    for (final on in [true, false]) {
      enabled = on;
      final rec = recorder();
      final rs = session(1, 'com.a')..secureFocus = true;
      rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
      rs.composer.setDraft('synthetic private draft');
      rs.secureFocus = false;
      rs.composer.setDraft('synthetic private draft edited');
      await settle();
      expect(drafts().load('h1/com.a'), isNull);
      await rec.sessionEnded(rs, meta('h1', 'com.a'));
      expect(lines(), isEmpty);
      expect(drafts().load('h1/com.a'), isNull);
    }
  });

  test('private failed sends stay private across retry, adoption and putBack', () async {
    final rec = recorder();
    final old = session(1, 'com.a')..secureFocus = true;
    final fresh = session(2, 'com.a');
    rec.attach(old, () => meta('h1', 'com.a'), restore: true);
    rec.attach(fresh, () => meta('h1', 'com.a'), restore: false);
    final row = (await send(old, 'synthetic private send'))!;
    old.secureFocus = false;
    old.composer.done(0, 'synthetic failure');
    expect(old.composer.retry(row), isNotNull);
    old.composer.done(0, 'synthetic failure');
    final moved = fresh.composer.adoptFrom(old.composer);
    rec.detach(old, to: fresh, moved: moved);
    final adopted = fresh.composer.failed.single;
    expect(fresh.composer.retry(adopted), isNotNull);
    fresh.composer.done(0, 'synthetic failure');
    fresh.composer.putBack(adopted);
    await settle();
    expect(fresh.composer.draftText, 'synthetic private send');
    expect(lines(), isEmpty);
    expect(drafts().load('h1/com.a'), isNull);
    final submitted = await fresh.composer.submit();
    expect(submitted, isA<SubmitPieces>());
    fresh.composer.done(1, null);
    await rec.sessionEnded(fresh, meta('h1', 'com.a'));
    expect(lines(), isEmpty);
    expect(drafts().load('h1/com.a'), isNull);
  });

  test('private blocks remain private when a failed block-only send goes back into the editor', () async {
    final rec = recorder();
    final rs = session(1, 'com.a')..secureFocus = true;
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    final row = (await send(rs, '', blocks: const [
      BlockChip(1, 'private block label', kind: 'text', text: 'synthetic private block'),
    ]))!;
    rs.secureFocus = false;
    rs.composer.done(0, 'synthetic failure');
    rs.composer.putBack(row);
    await rs.composer.submit();
    rs.composer.done(1, null);
    await settle();
    expect(lines(), isEmpty);
    expect(drafts().load('h1/com.a'), isNull);
  });

  test('retrying a private row does not taint a separate ordinary draft', () async {
    final rec = recorder();
    final rs = session(1, 'com.a')..secureFocus = true;
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    final row = (await send(rs, 'synthetic private send'))!;
    rs.secureFocus = false;
    rs.composer.done(0, 'synthetic failure');
    rs.composer.setDraft('ordinary unsent draft');
    rs.composer.retry(row);
    rs.composer.done(1, null);
    await rec.sessionEnded(rs, meta('h1', 'com.a'));
    expect(lines().single['text'], 'ordinary unsent draft');
  });

  test('three sends to two sessions make three lines with every field', () async {
    final rec = recorder();
    final written = <Map<String, Object?>>[];
    rec.written.listen(written.add);
    final a = session(1, 'com.a'), b = session(2, 'com.b', after: AfterSend.pressReturn);
    rec.attach(a, () => meta('h1', 'com.a', run: 'ra'), restore: true);
    rec.attach(b, () => meta('h2', 'com.b', run: 'rb'), restore: true);
    await send(a, '第一段', blocks: const [
      BlockChip(1, '图片 #1 1440×900', kind: 'image', bytes: 182044),
      BlockChip(2, '文字 #2 12 行', kind: 'text', bytes: 30, text: '粘贴的长文字'),
      BlockChip(3, 'a.pdf', kind: 'file', bytes: 5, name: 'a.pdf'),
    ]);
    a.composer.done(4, null);
    await until(() => lines().length == 1);
    await send(a, '第二段');
    a.composer.done(1, null);
    await send(b, '第三段');
    b.composer.done(1, null);
    await until(() => lines().length == 3);
    final l = lines();
    expect(l.length, 3);
    expect(written.length, 3);
    final iso = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$');
    for (final r in l) {
      expect(r['v'], 1);
      expect((r['id'] as String).length, 26);
      expect(r['ts'] as String, matches(iso));
      expect(r['kind'], 'sent');
      expect(r['from'], {'id': 'dev1', 'name': 'bruce-tablet'});
      expect(r['window'], {'id': 7, 'title': title});
      expect(r['projects'], ['rapp']);
      expect(r['result'], 'sent');
      expect(r.containsKey('sentPieces'), false);
      expect(r['source'], 'typed');
    }
    expect(l.map((r) => r['text']), ['第一段', '第二段', '第三段']);
    expect(l[0]['host'], {'id': 'h1', 'name': 'host-h1'});
    expect(l[0]['app'], {'id': 'com.a', 'name': 'App com.a'});
    expect(l[0]['session'], 'h1/com.a');
    expect(l[0]['run'], 'ra');
    expect(l[1]['run'], 'ra');
    expect(l[2]['host'], {'id': 'h2', 'name': 'host-h2'});
    expect(l[2]['app'], {'id': 'com.b', 'name': 'App com.b'});
    expect(l[2]['session'], 'h2/com.b');
    expect(l[2]['run'], 'rb');
    expect(l[0]['blocks'], [
      {'kind': 'image', 'label': '图片 #1 1440×900', 'bytes': 182044},
      {'kind': 'text', 'label': '文字 #2 12 行', 'bytes': 30, 'text': '粘贴的长文字'},
      {'kind': 'file', 'label': 'a.pdf', 'bytes': 5, 'name': 'a.pdf'},
    ]);
    expect(l[1]['blocks'], isEmpty);
    expect(l.map((r) => r['after']), ['none', 'none', 'return']);
    expect(jsonEncode(written), jsonEncode(l));
  });

  test('a partial and a failed round are recorded as such', () async {
    final rec = recorder();
    final rs = session(1, 'com.a', after: AfterSend.pressReturn);
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    await send(rs, '一半', blocks: const [BlockChip(1, '图片 #1', kind: 'image', bytes: 9)]);
    rs.composer.done(1, 'x');
    await until(() => lines().length == 1);
    await send(rs, '没发出');
    rs.linkDown();
    await until(() => lines().length == 2);
    final l = lines();
    expect(l[0]['result'], 'partial');
    expect(l[0]['sentPieces'], 1);
    expect(l[0]['after'], 'none');
    expect(l[1]['result'], 'failed');
    expect(l[1].containsKey('sentPieces'), false);
    expect(l[1]['after'], 'none');
    // Everything went but the round said something: no Return was pressed.
    await send(rs, '都发了');
    rs.composer.done(1, '回车没按上');
    await send(rs, '都发了也按了');
    rs.composer.done(1, null);
    await until(() => lines().length == 4);
    expect([for (final r in lines().skip(2)) (r['result'], r['after'])], [('sent', 'none'), ('sent', 'return')]);
  });

  test('the draft file outlives the send until its record is written', () async {
    final rec = recorder();
    final rs = session(1, 'com.a');
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    await send(rs, '原文');
    await settle();
    final f = drafts().load('h1/com.a')!;
    expect(f.pending, ['原文']);
    expect(f.text, '');
    expect(f.meta['key'], 'h1/com.a');
    expect(f.meta['record'], true);
    rs.composer.done(1, null);
    await until(() => lines().length == 1 && drafts().load('h1/com.a') == null);
    expect(lines().single['text'], '原文');
    expect(File(drafts().pathFor('h1/com.a')).existsSync(), false);
  });

  test('a restore puts the pieces and the draft back once and empties pending', () async {
    await drafts().save(DraftFile(key: 'h1/com.a', text: '还在写', pending: ['断在半路']));
    final rec = recorder();
    final rs = session(1, 'com.a');
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    expect(rs.composer.draft, '断在半路\n还在写');
    await settle();
    final f = drafts().load('h1/com.a')!;
    expect(f.pending, isEmpty);
    expect(f.text, '断在半路\n还在写');
    final other = session(2, 'com.a');
    rec.attach(other, () => meta('h1', 'com.a'), restore: false);
    expect(other.composer.draft, '');
  });

  test('sessionEnded turns the draft into a draft record and deletes the file', () async {
    final rec = recorder();
    final rs = session(1, 'com.a');
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    await send(rs, '在路上');
    rs.composer.setDraft('没写完');
    await settle();
    await rec.sessionEnded(rs, meta('h1', 'com.a'));
    final r = lines().single;
    expect(r['kind'], 'draft');
    expect(r['text'], '在路上\n没写完');
    expect(r.containsKey('result'), false);
    expect(r.containsKey('after'), false);
    expect(r['session'], 'h1/com.a');
    expect(r['from'], {'id': 'dev1', 'name': 'bruce-tablet'});
    expect((r['id'] as String).length, 26);
    await settle();
    expect(drafts().load('h1/com.a'), isNull);
  });

  test('sweep leaves fresh drafts and apps that do not record', () async {
    final old = DateTime.now().subtract(const Duration(days: 8));
    final m = meta('h1', 'com.a').toJson();
    await drafts().save(DraftFile(key: 'h1/com.a', text: '旧草稿', pending: ['旧的一段'], meta: {...m, 'record': true}));
    await drafts().save(DraftFile(key: 'h1/com.b', text: '不记', meta: {...meta('h1', 'com.b').toJson(), 'record': false}));
    await drafts().save(DraftFile(key: 'h1/com.c', text: '新草稿', meta: {...meta('h1', 'com.c').toJson(), 'record': true}));
    File(drafts().pathFor('h1/com.a')).setLastModifiedSync(old);
    File(drafts().pathFor('h1/com.b')).setLastModifiedSync(old);
    await recorder().sweep();
    final r = lines().single;
    expect(r['kind'], 'draft');
    expect(r['text'], '旧的一段\n旧草稿');
    expect(r['host'], {'id': 'h1', 'name': 'host-h1'});
    expect(r['app'], {'id': 'com.a', 'name': 'App com.a'});
    expect(r['run'], 'run1');
    expect(r['window'], {'id': 7, 'title': title});
    expect(drafts().load('h1/com.a'), isNull);
    expect(drafts().load('h1/com.b'), isNotNull);
    expect(drafts().load('h1/com.c'), isNotNull);
    expect(logs, contains('rapp: 输入记录 清理 1 份草稿'));
    enabled = false;
    File(drafts().pathFor('h1/com.c')).setLastModifiedSync(old);
    await recorder().sweep();
    expect(drafts().load('h1/com.c'), isNotNull);
    expect(lines().length, 1);
  });

  test('with either switch off nothing is recorded but drafts still come back', () async {
    for (final off in ['inputHistory', 'recordInput']) {
      enabled = off != 'inputHistory';
      final rec = recorder();
      final rs = session(1, 'com.a', record: off != 'recordInput');
      rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
      await send(rs, '发出去的');
      rs.composer.done(1, null);
      rs.composer.setDraft('留着的');
      await settle();
      expect(Directory(data.inputsDir('dev1')).existsSync(), false, reason: off);
      expect(drafts().load('h1/com.a')!.pending, isEmpty, reason: off);
      await rec.sessionEnded(rs, meta('h1', 'com.a'));
      await settle();
      expect(drafts().load('h1/com.a')!.text, '留着的', reason: off);
      final again = session(2, 'com.a', record: off != 'recordInput');
      recorder().attach(again, () => meta('h1', 'com.a'), restore: true);
      expect(again.composer.draft, '留着的', reason: off);
      await drafts().delete('h1/com.a');
    }
  });

  test('what is sent into a password field on A is never recorded, and recording comes back after', () async {
    final rec = recorder();
    final rs = session(1, 'com.a');
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    rs.apply(const SecureFocusEvent(1, true));
    await send(rs, 'hunter2');
    rs.composer.done(1, null);
    await settle();
    expect(lines(), isEmpty);
    expect(drafts().load('h1/com.a')?.pending ?? const [], isEmpty);
    rs.apply(const SecureFocusEvent(1, false));
    await send(rs, '普通的');
    rs.composer.done(1, null);
    await until(() => lines().isNotEmpty);
    expect([for (final l in lines()) l['text']], ['普通的']);
  });

  test('a failed write does not stop the send and is said once', () async {
    File(data.inputsDir('dev1')).writeAsStringSync('in the way');
    final rec = recorder();
    final rs = session(1, 'com.a');
    var notes = 0;
    rs.composer.addListener(() {
      if (rs.composer.status?.startsWith('输入记录没写进去：') ?? false) notes++;
    });
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    await send(rs, '一');
    rs.composer.done(1, null);
    await settle();
    final said = notes;
    expect(said, greaterThan(0));
    rs.composer.status = null;
    await send(rs, '二');
    rs.composer.done(1, null);
    await settle();
    expect(port.calls.where((c) => c.$1 == 'composer_send').length, 2);
    expect(notes, said, reason: 'said once');
    final f = drafts().load('h1/com.a')!;
    expect(f.pending, isEmpty, reason: 'a finished round is no unsent text');
    expect([for (final r in f.records) (r['text'], r['result'])], [('一', 'sent'), ('二', 'sent')]);
    expect(logs.where((l) => l.startsWith('rapp: 输入记录 写入失败')), isNotEmpty);
    // A write that goes resets it (the next failure is said again) and takes the kept ones along.
    File(data.inputsDir('dev1')).deleteSync();
    await send(rs, '三');
    rs.composer.done(1, null);
    await until(() => lines().length == 3);
    await settle();
    expect(lines().map((r) => r['text']), ['三', '一', '二']);
    expect(lines()[1]['from'], {'id': 'dev1', 'name': 'bruce-tablet'});
    expect(drafts().load('h1/com.a'), isNull);
    expect(logs, contains('rapp: 输入记录 补写 2 条'));
    Directory(data.inputsDir('dev1')).deleteSync(recursive: true);
    File(data.inputsDir('dev1')).writeAsStringSync('in the way');
    rs.composer.status = null;
    await send(rs, '四');
    rs.composer.done(1, null);
    await settle();
    expect(notes, greaterThan(said));
  });

  test('a failed round whose write failed waits as a record; its retry is pending once', () async {
    File(data.inputsDir('dev1')).writeAsStringSync('in the way');
    final rec = recorder();
    final rs = session(1, 'com.a');
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    final o = (await send(rs, '重试的'))!;
    rs.composer.done(0, 'x');
    await settle();
    expect(rs.composer.retry(o), isNotNull);
    await settle();
    final f = drafts().load('h1/com.a')!;
    expect(f.pending, ['重试的']);
    expect([for (final r in f.records) (r['text'], r['result'])], [('重试的', 'failed')]);
  });

  test('without a device id the reason says so', () async {
    File('${data.localDir}/service.json').deleteSync();
    final rec = recorder();
    final rs = session(1, 'com.a');
    final seen = <String>[];
    rs.composer.addListener(() {
      final s = rs.composer.status;
      if (s != null) seen.add(s);
    });
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    await send(rs, '一');
    rs.composer.done(1, null);
    await settle();
    expect(seen, contains('输入记录没写进去：还不知道这台设备的 id'));
    final f = drafts().load('h1/com.a')!;
    expect(f.pending, isEmpty);
    expect(f.records.single['text'], '一');
    expect(f.records.single['from'], isNull);
    // Once the id is there, the kept record goes with it.
    File('${data.localDir}/service.json').writeAsStringSync('{"id":"dev1"}');
    await send(rs, '二');
    rs.composer.done(1, null);
    await until(() => lines().length == 2);
    expect(lines().map((r) => r['text']), ['二', '一']);
    expect(lines()[1]['from'], {'id': 'dev1', 'name': 'bruce-tablet'});
  });

  test('window and projects are the ones at hand-off, also on a retry', () async {
    final rec = recorder();
    final rs = session(1, 'com.a');
    var w = 7;
    rec.attach(rs, () => meta('h1', 'com.a')..windowId = w, restore: true);
    await send(rs, '交出去');
    w = 8; // the tab changed before done
    rs.composer.done(1, null);
    await until(() => lines().length == 1);
    expect(lines().single['window'], {'id': 7, 'title': title});
    final o = (await send(rs, '再试'))!;
    rs.composer.done(0, 'x');
    w = 9;
    rs.composer.retry(o);
    w = 10;
    rs.composer.done(1, null);
    await until(() => lines().length == 3);
    expect([for (final r in lines()) (r['window'] as Map)['id']], [7, 8, 9]);
  });

  test('a swap mid-send: the piece follows its adopted row, a retry is pending once', () async {
    final rec = recorder();
    final old = session(1, 'com.a'), fresh = session(11, 'com.a');
    rec.attach(old, () => meta('h1', 'com.a'), restore: true);
    rec.attach(fresh, () => meta('h1', 'com.a'), restore: false);
    await send(old, '在路上'); // a move: no done comes for the old session
    final moved = fresh.composer.adoptFrom(old.composer);
    rec.detach(old, to: fresh, moved: moved);
    await settle();
    expect(drafts().load('h1/com.a')!.pending, ['在路上']);
    final row = fresh.composer.failed.single;
    expect(fresh.composer.retry(row), isNotNull);
    await settle();
    expect(drafts().load('h1/com.a')!.pending, ['在路上'], reason: 'once');
    fresh.composer.done(1, null);
    await until(() => lines().length == 1 && drafts().load('h1/com.a') == null);
    expect(lines().single['text'], '在路上');
    expect(lines().single['result'], 'sent');
  });

  test('a session that goes with nobody to take over keeps its piece for the next open', () async {
    final rec = recorder();
    final old = session(1, 'com.a');
    rec.attach(old, () => meta('h1', 'com.a'), restore: true);
    await send(old, '在路上');
    rec.detach(old);
    await settle();
    expect(drafts().load('h1/com.a')!.pending, ['在路上']);
    final next = session(21, 'com.a');
    rec.attach(next, () => meta('h1', 'com.a'), restore: true);
    expect(next.composer.draft, '在路上');
  });

  test('a failed write then a swap: the record waits in the file and goes with the next write', () async {
    File(data.inputsDir('dev1')).writeAsStringSync('in the way');
    final rec = recorder();
    final old = session(1, 'com.a'), fresh = session(11, 'com.a');
    rec.attach(old, () => meta('h1', 'com.a'), restore: true);
    rec.attach(fresh, () => meta('h1', 'com.a'), restore: false);
    await send(old, '断了');
    old.linkDown();
    await settle();
    rec.detach(old, to: fresh, moved: fresh.composer.adoptFrom(old.composer));
    await settle();
    final f = drafts().load('h1/com.a')!;
    expect(f.pending, isEmpty);
    expect([for (final r in f.records) (r['text'], r['result'])], [('断了', 'failed')]);
    File(data.inputsDir('dev1')).deleteSync();
    await send(fresh, '下一段');
    fresh.composer.done(1, null);
    await until(() => lines().length == 2);
    expect(lines().map((r) => (r['text'], r['result'])), [('下一段', 'sent'), ('断了', 'failed')]);
  });

  test('a failed write then the end: a sent record, and no draft record of that text', () async {
    File(data.inputsDir('dev1')).writeAsStringSync('in the way');
    final rec = recorder();
    final rs = session(1, 'com.a');
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    await send(rs, '发出去了');
    rs.composer.done(1, null);
    rs.composer.setDraft('没写完');
    await settle();
    File(data.inputsDir('dev1')).deleteSync();
    await rec.sessionEnded(rs, meta('h1', 'com.a'));
    expect([for (final r in lines()) (r['kind'], r['text'])], [('sent', '发出去了'), ('draft', '没写完')]);
    await settle();
    expect(drafts().load('h1/com.a'), isNull);
  });

  test('a failed write then a crash: the reopen does not bring the sent text back, it appends it', () async {
    File(data.inputsDir('dev1')).writeAsStringSync('in the way');
    final rs = session(1, 'com.a');
    recorder().attach(rs, () => meta('h1', 'com.a'), restore: true);
    await send(rs, '发出去了');
    rs.composer.done(1, null);
    await settle();
    expect(drafts().load('h1/com.a')!.records, hasLength(1));
    // Killed; the next start can write.
    File(data.inputsDir('dev1')).deleteSync();
    final again = session(2, 'com.a');
    recorder().attach(again, () => meta('h1', 'com.a'), restore: true);
    expect(again.composer.draft, '');
    await until(() => lines().length == 1 && drafts().load('h1/com.a') == null);
    expect(lines().single['text'], '发出去了');
    expect(lines().single['result'], 'sent');
    expect(drafts().load('h1/com.a'), isNull);
  });

  test('ending a session that never went live turns its file into a draft record', () async {
    await drafts().save(DraftFile(
        key: 'h1/com.a', text: '上次的', pending: ['半路的'], meta: {...meta('h1', 'com.a').toJson(), 'record': true}));
    final rec = recorder();
    await rec.sessionEnded(null, meta('h1', 'com.a'), record: true);
    final r = lines().single;
    expect(r['kind'], 'draft');
    expect(r['text'], '半路的\n上次的');
    await settle();
    expect(drafts().load('h1/com.a'), isNull);
    // An app that does not record keeps its file.
    await drafts().save(DraftFile(key: 'h1/com.b', text: '不记'));
    await rec.sessionEnded(null, meta('h1', 'com.b'), record: false);
    await settle();
    expect(drafts().load('h1/com.b')!.text, '不记');
    expect(lines(), hasLength(1));
  });

  test('sweep follows the app\'s switch now, not the one saved in the draft', () async {
    final old = DateTime.now().subtract(const Duration(days: 8));
    await drafts().save(DraftFile(key: 'h1/com.a', text: '后来关了', meta: {...meta('h1', 'com.a').toJson(), 'record': true}));
    File(drafts().pathFor('h1/com.a')).setLastModifiedSync(old);
    appsOff = {'com.a'};
    await recorder().sweep();
    expect(lines(), isEmpty);
    expect(drafts().load('h1/com.a'), isNotNull);
  });

  test('a flush for another session skips a draft whose app is off now', () async {
    await drafts().save(DraftFile(
        key: 'h1/com.b',
        text: '',
        records: [
          {'v': 1, 'id': '01B', 'ts': '2026-11-14T10:00:00+09:00', 'kind': 'sent', 'text': '等着的'}
        ],
        meta: {...meta('h1', 'com.b').toJson(), 'record': true}));
    final rec = recorder();
    final other = session(1, 'com.a');
    rec.attach(other, () => meta('h1', 'com.a'), restore: true);
    appsOff = {'com.b'};
    final b = session(2, 'com.b', record: false);
    rec.attach(b, () => meta('h1', 'com.b'), restore: false); // loads b's draft into the recorder
    rec.detach(b);
    await send(other, '发出去的');
    other.composer.done(1, null);
    await until(() => lines().isNotEmpty);
    await settle();
    expect(lines().map((r) => r['text']), ['发出去的']);
    expect(drafts().load('h1/com.b')!.records, hasLength(1));
  });

  test('a put-back row is not pending any more once the text is in the editor', () async {
    final rec = recorder();
    final old = session(1, 'com.a'), fresh = session(11, 'com.a');
    rec.attach(old, () => meta('h1', 'com.a'), restore: true);
    rec.attach(fresh, () => meta('h1', 'com.a'), restore: false);
    await send(old, '在路上');
    final moved = fresh.composer.adoptFrom(old.composer);
    rec.detach(old, to: fresh, moved: moved);
    await settle();
    expect(drafts().load('h1/com.a')!.pending, ['在路上']);
    fresh.composer.putBack(fresh.composer.failed.single);
    fresh.composer.setDraft('在路上');
    await settle();
    final f = drafts().load('h1/com.a')!;
    expect(f.pending, isEmpty);
    expect(f.text, '在路上');
  });

  test('the log never carries the text', () async {
    final texts = ['秘密的第一段', '秘密的草稿', '旧的秘密', title];
    final old = DateTime.now().subtract(const Duration(days: 8));
    await drafts().save(
        DraftFile(key: 'h9/com.z', text: '旧的秘密', meta: {...meta('h9', 'com.z').toJson(), 'record': true}));
    File(drafts().pathFor('h9/com.z')).setLastModifiedSync(old);
    final rec = recorder();
    await rec.sweep();
    Directory(data.inputsDir('dev1')).renameSync('${tmp.path}/moved');
    File(data.inputsDir('dev1')).writeAsStringSync('in the way');
    final rs = session(1, 'com.a');
    rec.attach(rs, () => meta('h1', 'com.a'), restore: true);
    await send(rs, '秘密的第一段');
    rs.composer.done(1, null);
    rs.composer.setDraft('秘密的草稿');
    await settle();
    await rec.sessionEnded(rs, meta('h1', 'com.a'));
    expect(logs, isNotEmpty);
    for (final l in logs) {
      for (final t in texts) {
        expect(l.contains(t), false, reason: l);
      }
    }
  });
}
