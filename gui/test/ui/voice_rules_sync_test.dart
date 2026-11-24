// The device voice rules (plan 2026-11-25-rapp-voice-local-fix Task 2; spec D4, D7, D10, D18): a copy in
// `local/voice-rules.json`, synced from the gateway at the hotwords' times, learned rules applied at once.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/tidy_diff.dart';
import 'package:rapp/embed/voice_fix.dart';
import 'package:rapp/embed/voice_ring.dart' show VoicePick;
import 'package:rapp/hub_client.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

class _FakeApi extends LlmApi {
  final calls = <LlmCall>[];
  final learns = <LearnItem>[];

  /// The etag each rules ask sent.
  final rulesAsks = <String?>[];
  Future<RulesReply?> Function(String? etag) answer = (_) async => null;

  @override
  Future<RulesReply?> rules(LlmEndpoint e, {String? etag}) {
    rulesAsks.add(etag);
    return answer(etag);
  }

  @override
  Future<bool> learn(LlmEndpoint e, LearnItem item) async {
    learns.add(item);
    return true;
  }

  @override
  Future<bool> forget(LlmEndpoint e, String id) async => true;

  @override
  Future<List<String>> hotwords(LlmEndpoint e) async => const [];

  @override
  LlmCall run(LlmEndpoint e, String app, String input,
      {Map<String, String>? vars, void Function(String text)? onText, Duration firstByte = const Duration(seconds: 10), bool think = false}) {
    final c = LlmCall.manual();
    calls.add(c);
    return c;
  }
}

const ep = LlmEndpoint(url: 'localhost:28001', key: 'k');
const xu = FixRule.replace('徐逊', '徐迅', FixSource.vocabulary);

RulesReply full(String etag, List<FixRule> rules) => RulesReply(unchanged: false, etag: etag, rules: rules);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late DataDir d;
  late _FakeApi api;
  final sid = 'com.a'.length;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('voice_rules_sync');
    d = DataDir(tmp.path);
    Directory(d.localDir).createSync(recursive: true);
    File('${d.localDir}/service.json').writeAsStringSync('{"id":"dev1"}');
    Directory(d.deviceDir('dev1')).createSync(recursive: true);
    File('${d.deviceDir('dev1')}/device.json').writeAsStringSync('{"name":"bruce-tablet"}');
    ep.save(d.localDir);
    api = _FakeApi();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  File copyFile() => File('${d.localDir}/$voiceRulesFile');
  Map<String, Object?> copyJson() => (jsonDecode(copyFile().readAsStringSync()) as Map).cast<String, Object?>();

  RemoteWindow win(int id) => RemoteWindow(
        id: id,
        parent: 0,
        kind: WindowKind.normal,
        title: 'w$id',
        rect: const Rect.fromLTWH(0, 0, 400, 328),
        titleBar: 28,
        resizable: true,
        focused: false,
        texture: id,
        visible: const Rect.fromLTWH(0, 0, 1, 1),
      );

  // com.a open on 111 with a picture, the 接入点 read from local/llm.json at start.
  Future<(MainState, FakeSessionPort)> start({DateTime Function()? clock}) async {
    final t = FakeTransport();
    final port = FakeSessionPort();
    final h = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await pump();
    final st = MainState(hub: h, data: d, prefs: UiPrefs(), port: port, llmApi: api, clock: clock)
      ..tidySettle = Duration.zero
      ..tidyRevealMax = Duration.zero;
    t.onSend = (m) {
      if (m['cmd'] != 'open') return;
      final n = (m['app'] as String).length;
      t.emit({
        'event': 'opened', 'sid': n, 'id': '111', 'app': m['app'], 'path': 'lan',
        'port': 5000 + n, 'token': 'tk', 'req': m['req'],
      });
    };
    await st.openOrSwitch('111', 'com.a', 'A');
    await until(() => st.currentRemote != null);
    port.emit(WindowsEvent(sid, [win(3)]));
    return (st, port);
  }

  test('rules 200 writes the copy and fixes at once', () async {
    api.answer = (_) async => full('e1', const [xu]);
    final (st, _) = await start();
    await until(() => !st.voiceRules.isEmpty);
    expect(st.voiceFix(sid, '徐逊来了').text, '徐迅来了');
    expect(copyFile().existsSync(), isTrue);
    if (!Platform.isWindows) expect(copyFile().statSync().modeString(), 'rw-------');
    final j = copyJson();
    expect(j['endpoint'], 'http://localhost:28001');
    expect(j['etag'], 'e1');
    expect(j['rules'], [xu.toJson()]);
    st.dispose();
  });

  test('304 keeps the rules and moves fetchedAt', () async {
    var now = DateTime.utc(2026, 11, 25, 9);
    api.answer = (_) async => full('e1', const [xu]);
    final (st, _) = await start(clock: () => now);
    await until(() => !st.voiceRules.isEmpty);
    expect(DateTime.parse(copyJson()['fetchedAt'] as String), now);
    api.answer = (etag) async => RulesReply(unchanged: true, etag: etag!, rules: const []);
    final asked = api.rulesAsks.length;
    now = now.add(const Duration(minutes: 9));
    st.voiceHotwords(); // not old yet
    await pump();
    expect(api.rulesAsks.length, asked);
    now = now.add(const Duration(minutes: 2));
    st.voiceHotwords();
    await until(() => DateTime.parse(copyJson()['fetchedAt'] as String) == now);
    expect(api.rulesAsks.length, asked + 1);
    expect(api.rulesAsks.last, 'e1');
    expect(st.voiceFix(sid, '徐逊来了').text, '徐迅来了');
    expect(copyJson()['rules'], [xu.toJson()]);
    st.dispose();
  });

  test('a failure keeps the copy', () async {
    api.answer = (_) async => full('e1', const [xu]);
    final (st, _) = await start();
    await until(() => !st.voiceRules.isEmpty);
    final before = copyFile().readAsStringSync();
    api.answer = (_) async => null;
    final asked = api.rulesAsks.length;
    await st.forgetLearned('id1');
    await until(() => api.rulesAsks.length > asked);
    await pump();
    expect(st.voiceFix(sid, '徐逊来了').text, '徐迅来了');
    expect(copyFile().readAsStringSync(), before);
    st.dispose();
  });

  test('a copy from another endpoint is not used', () async {
    await VoiceRulesCopy(endpoint: 'http://elsewhere:28001', fetchedAt: DateTime.utc(2026, 11, 25), etag: 'e0', rules: const [xu])
        .save(d.localDir);
    final (st, _) = await start();
    await until(() => api.rulesAsks.isNotEmpty);
    await pump();
    expect(st.voiceRules.isEmpty, isTrue);
    expect(st.voiceFix(sid, '徐逊来了').changed, isFalse);
    expect(api.rulesAsks.single, isNull); // that copy's etag is not this gateway's
    st.dispose();
  });

  test('a copy is used at start before the gateway answers', () async {
    await VoiceRulesCopy(endpoint: 'http://localhost:28001', fetchedAt: DateTime.utc(2026, 11, 25), etag: 'e0', rules: const [xu])
        .save(d.localDir);
    api.answer = (_) => Completer<RulesReply?>().future; // never
    final (st, _) = await start();
    await until(() => !st.voiceRules.isEmpty);
    expect(st.voiceFix(sid, '徐逊来了').text, '徐迅来了');
    expect(api.rulesAsks, ['e0']);
    st.voiceHotwords();
    await pump();
    expect(api.rulesAsks, ['e0'], reason: 'one rules ask in flight at a time');
    st.dispose();
  });

  test('voiceFix leaves secure focus alone', () async {
    api.answer = (_) async => full('e1', const [xu]);
    final (st, port) = await start();
    await until(() => !st.voiceRules.isEmpty);
    port.emit(SecureFocusEvent(sid, true));
    final r = st.voiceFix(sid, '徐逊来了');
    expect(r.text, '徐逊来了');
    expect(r.changed, isFalse);
    expect(st.voiceFix(999, '徐逊来了').changed, isFalse, reason: 'no such session: as if secure');
    st.dispose();
  });

  test('learning writes the rule locally first', () async {
    api.answer = (_) async => full('e1', const [FixRule.replace('拍森', '派森', FixSource.vocabulary), xu]);
    final (st, _) = await start();
    await until(() => !st.voiceRules.isEmpty);
    final pending = Completer<RulesReply?>();
    api.answer = (_) => pending.future;
    final asked = api.rulesAsks.length;

    // The edit pick, then the user fixes a word and remembers it.
    final rs = st.currentRemote!;
    st.tidyOf(sid).begin('嗯那个我们明天用拍森开会', VoicePick.edit);
    api.calls.single.complete(const LlmDone('我们明天用拍森开会。'));
    await pump();
    final e = FakeEditor();
    await rs.composer.attach(e);
    e.value = '我们明天用Python开会。';
    await rs.composer.submit();
    st.tidyOf(sid).remember();
    await until(() => api.learns.isNotEmpty);
    await until(() => st.voiceFix(sid, '拍森').text == 'Python');

    expect(st.voiceFix(sid, '用拍森跑').text, '用Python跑');
    expect(st.voiceFix(sid, '徐逊').text, '徐迅', reason: 'the other rules stay');
    final rules = (copyJson()['rules'] as List).cast<Map>();
    expect(rules.where((r) => r['observed'] == '拍森'), [const FixRule.replace('拍森', 'Python', FixSource.learned).toJson()]);
    await until(() => api.rulesAsks.length > asked);
    expect(api.rulesAsks.length, asked + 1);
    expect(api.rulesAsks.last, isNull, reason: 'the copy is no longer the gateway\'s e1');
    st.dispose();
  });

  test('forget refetches', () async {
    api.answer = (_) async => full('e1', const [xu]);
    final (st, _) = await start();
    await until(() => !st.voiceRules.isEmpty);
    final pending = Completer<RulesReply?>();
    api.answer = (_) => pending.future;
    final asked = api.rulesAsks.length;
    expect(await st.forgetLearned('id1'), isTrue);
    await until(() => api.rulesAsks.length > asked);
    expect(api.rulesAsks.length, asked + 1);
    expect(st.voiceFix(sid, '徐逊来了').text, '徐迅来了', reason: 'nothing is taken away here');
    pending.complete(full('e2', const []));
    await until(() => st.voiceRules.isEmpty);
    expect(copyJson()['etag'], 'e2');
    st.dispose();
  });

  test('a new endpoint drops the rules until it answers', () async {
    api.answer = (_) async => full('e1', const [xu]);
    final (st, _) = await start();
    await until(() => !st.voiceRules.isEmpty);
    final pending = Completer<RulesReply?>();
    api.answer = (_) => pending.future;
    st.setLlm(const LlmEndpoint(url: 'localhost:28002', key: 'k'));
    expect(st.voiceRules.isEmpty, isTrue);
    pending.complete(full('f1', const [FixRule.replace('拍森', 'Python', FixSource.vocabulary)]));
    await until(() => !st.voiceRules.isEmpty);
    expect(st.voiceFix(sid, '拍森').text, 'Python');
    expect(copyJson()['endpoint'], 'http://localhost:28002');
    st.setLlm(const LlmEndpoint());
    expect(st.voiceRules.isEmpty, isTrue, reason: 'no endpoint, no rules');
    st.dispose();
  });

  test('an answer asked before a change is dropped and asked again', () async {
    api.answer = (_) async => full('e1', const [xu]);
    final (st, _) = await start();
    await until(() => !st.voiceRules.isEmpty);
    final first = Completer<RulesReply?>();
    api.answer = (_) => first.future;
    await st.forgetLearned('a');
    final asked = api.rulesAsks.length;
    await st.forgetLearned('b'); // while the first is out
    await pump();
    expect(api.rulesAsks.length, asked, reason: 'one in flight');
    api.answer = (_) async => full('e3', const []);
    first.complete(full('e2', const [FixRule.replace('拍森', 'Python', FixSource.vocabulary)]));
    await until(() => api.rulesAsks.length > asked);
    await until(() => st.voiceRules.isEmpty);
    expect(copyJson()['etag'], 'e3');
    st.dispose();
  });
}
