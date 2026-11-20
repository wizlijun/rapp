// 长语音先让 AI 整理 wired into MainState (plan 2026-11-20-rapp-voice-ai-tidy Task 4).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/voice_ring.dart' show VoicePick;
import 'package:rapp/embed/voice_tidy.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

class _FakeApi extends LlmApi {
  final calls = <LlmCall>[];

  @override
  LlmCall run(LlmEndpoint e, String app, String input,
      {Map<String, String>? vars, void Function(String text)? onText, Duration firstByte = const Duration(seconds: 10)}) {
    final c = LlmCall.manual();
    calls.add(c);
    return c;
  }
}

const long = '嗯那个我门明天下午三点开会';
const tidied = '我们明天下午三点开会。';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late DataDir d;
  late _FakeApi api;
  const key = '111/com.a';
  final sid = 'com.a'.length;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('voice_tidy_wiring');
    d = DataDir(tmp.path);
    Directory(d.localDir).createSync(recursive: true);
    File('${d.localDir}/service.json').writeAsStringSync('{"id":"dev1"}');
    Directory(d.deviceDir('dev1')).createSync(recursive: true);
    File('${d.deviceDir('dev1')}/device.json').writeAsStringSync('{"name":"bruce-tablet"}');
    api = _FakeApi();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  // Twice: a done send's wait (tidySettle zero here) is a timer of its own. The words come out at once
  // (tidyRevealMax zero).
  Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));
  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  List<Map<String, Object?>> lines() {
    final dir = Directory(d.inputsDir('dev1'));
    if (!dir.existsSync()) return [];
    return [
      for (final f in dir.listSync().whereType<File>())
        for (final l in f.readAsLinesSync())
          if (l.isNotEmpty) (jsonDecode(l) as Map).cast<String, Object?>(),
    ];
  }

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

  // com.a open on 111 with a picture; a reconnect's open answers sid + 10. [endpoint]: the LLM 接入点 is set.
  // [held]: a reconnect's open is not answered but kept here, for the test to answer.
  Future<(MainState, FakeSessionPort)> start(
      {bool endpoint = true, List<void Function()>? held, void Function(String)? log}) async {
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
    final st = MainState(hub: h, data: d, prefs: UiPrefs(), port: port, llmApi: api, log: log)
      ..tidySettle = Duration.zero
      ..tidyRevealMax = Duration.zero;
    if (endpoint) st.setLlm(const LlmEndpoint(url: 'localhost:28001', key: 'k'));
    var reconnects = 0;
    t.onSend = (m) {
      if (m['cmd'] != 'open') return;
      final n = (m['app'] as String).length + (m['reconnect'] == true ? 10 * ++reconnects : 0);
      void answer() => t.emit({
            'event': 'opened', 'sid': n, 'id': '111', 'app': m['app'], 'path': 'lan',
            'port': 5000 + n, 'token': 'tk', 'req': m['req'],
          });
      if (held != null && m['reconnect'] == true) {
        held.add(answer);
      } else {
        answer();
      }
    };
    await st.openOrSwitch('111', 'com.a', 'A');
    await until(() => st.currentRemote != null);
    port.emit(WindowsEvent(sid, [win(3)]));
    return (st, port);
  }

  List<Object?> sends(FakeSessionPort port, Object s) =>
      [for (final c in port.calls) if (c.$1 == 'composer_send' && c.$2['sid'] == s) c.$2['pieces']];

  test('a long voice text goes to the tidy, a short one is sent', () async {
    final (st, _) = await start();
    expect(st.tidyOf(sid).begin('你好', VoicePick.send), isFalse);
    expect(st.tidyOf(sid).begin(long, VoicePick.send), isTrue);
    expect(st.tidyOf(sid).phase, TidyPhase.tidying);
    st.dispose();
  });

  test('done sends to the port with an AI record', () async {
    final (st, port) = await start();
    st.tidyOf(sid).begin(long, VoicePick.send);
    api.calls.single.complete(const LlmDone(tidied));
    await pump();
    expect(sends(port, sid), [
      [
        {'text': tidied}
      ]
    ]);
    st.currentRemote!.composer.done(1, null);
    await until(() => lines().length == 1);
    final r = lines().single;
    expect(r['text'], tidied);
    expect(r['source'], 'voice');
    expect(r['ai'], {'app': 'dictation', 'original': long, 'result': tidied});
    st.dispose();
  });

  test('the switch off skips the tidy', () async {
    final (st, _) = await start();
    expect(st.prefs.voiceAiTidy, isTrue);
    st.setVoiceAiTidy(false);
    expect(st.tidyOf(sid).begin(long, VoicePick.send), isFalse);
    expect(UiPrefs.load(d.deviceDir('dev1')).voiceAiTidy, isFalse);
    expect(jsonDecode(File('${d.deviceDir('dev1')}/gui.json').readAsStringSync())['voice_ai_tidy'], false);
    st.dispose();
  });

  test('no endpoint skips the tidy', () async {
    final (st, _) = await start(endpoint: false);
    final before = st.hint;
    expect(st.tidyOf(sid).begin(long, VoicePick.send), isFalse);
    expect(api.calls, isEmpty);
    expect(st.hint, before);
    st.dispose();
  });

  test('a secure focus skips the tidy', () async {
    final (st, port) = await start();
    port.emit(SecureFocusEvent(sid, true));
    expect(st.tidyOf(sid).begin(long, VoicePick.send), isFalse);
    st.dispose();
  });

  test('reconnect moves the tidy to the new session', () async {
    final (st, port) = await start();
    final tidy = st.tidyOf(sid);
    tidy.begin(long, VoicePick.send);
    port.emit(DisconnectedEvent(sid, 'boom'));
    await settle();
    await st.reconnect(key);
    await pump();
    port.emit(WindowsEvent(sid + 10, [win(3)]));
    await settle();
    expect(st.currentRemote!.sid, sid + 10);
    expect(st.tidyIfAny(sid), isNull);
    expect(st.tidyOf(sid + 10), same(tidy));
    expect(tidy.phase, TidyPhase.tidying);
    api.calls.single.complete(const LlmDone(tidied));
    await pump();
    expect(sends(port, sid + 10), [
      [
        {'text': tidied}
      ]
    ]);
    st.dispose();
  });

  // Review 2026-11-20 Important #1: the old session's end before the new one opens.
  test('the old session closing before the reconnect opens keeps the original', () async {
    final held = <void Function()>[];
    final (st, port) = await start(held: held);
    st.tidyOf(sid).begin(long, VoicePick.send); // still tidying when the link drops
    port.emit(DisconnectedEvent(sid, 'boom'));
    await settle();
    unawaited(st.reconnect(key));
    await until(() => held.isNotEmpty);
    port.emit(ClosedEvent(sid, 'gone'));
    await pump();
    expect(st.tidyIfAny(sid), isNull);
    held.single();
    await until(() => st.remote[sid + 10] != null);
    expect(st.remote[sid + 10]!.composer.draftText, contains(long));
    st.dispose();
  });

  // Review 2026-11-20 Important #2: the panel's editor is attached when the window goes.
  test('closing with the panel open keeps the original in its draft record', () async {
    final (st, port) = await start();
    final c = st.currentRemote!.composer;
    final e = FakeEditor();
    await c.attach(e);
    e.value = '我打的字'; // typed after the panel opened: not in the draft copy yet
    st.tidyOf(sid).begin(long, VoicePick.send);
    st.endCurrent();
    port.emit(ClosedEvent(sid, 'rapp-client: quit'));
    await until(() => lines().isNotEmpty);
    final text = lines().single['text'] as String;
    expect(text, contains('我打的字'));
    expect(text, contains(long));
    st.dispose();
  });

  // Review 2026-11-20 minors.
  test('quitting while a tidy runs brings the original back on the next open', () async {
    final (st, _) = await start();
    st.tidyOf(sid).begin(long, VoicePick.send);
    await pump();
    st.dispose(); // the app quits (or dies) with the card still waiting
    final (again, _) = await start();
    expect(again.currentRemote!.composer.draftText, contains(long));
    again.dispose();
    final (third, _) = await start();
    // It is in the draft now (drafts last across opens), and only once: the held copy went.
    expect(long.allMatches(third.currentRemote!.composer.draftText), hasLength(1));
    third.dispose();
  });

  test('a tidy that ended leaves nothing for the next open', () async {
    final (st, _) = await start();
    st.tidyOf(sid).begin(long, VoicePick.send);
    st.tidyOf(sid).sendNow();
    st.currentRemote!.composer.done(1, null);
    await until(() => lines().length == 1);
    st.dispose();
    final (again, _) = await start();
    expect(again.currentRemote!.composer.draftText, isNot(contains(long)));
    again.dispose();
  });

  test('asking for a closed session\'s tidy leaves none behind', () async {
    final (st, port) = await start();
    st.endCurrent();
    port.emit(ClosedEvent(sid, 'rapp-client: quit'));
    await until(() => st.remote[sid] == null);
    st.tidyOf(sid); // a last build of the gone session's layer
    expect(st.tidyIfAny(sid), isNull);
    st.dispose();
  });

  test('tidy lines go to the log', () async {
    final logged = <String>[];
    final (st, _) = await start(log: logged.add);
    st.tidyOf(sid).begin(long, VoicePick.send);
    api.calls.single.complete(const LlmDone(tidied));
    await pump();
    expect(logged.where((l) => l.contains('voice tidy: dictation start')), hasLength(1));
    expect(logged.where((l) => l.contains('voice tidy: dictation done')), hasLength(1));
    st.dispose();
  });

  test('a tidy in a background session says so in the hint', () async {
    final (st, port) = await start();
    st.tidyOf(sid).begin(long, VoicePick.send);
    await st.openOrSwitch('111', 'com.bb', 'B');
    await until(() => st.currentRemote?.sid == 'com.bb'.length);
    port.emit(WindowsEvent('com.bb'.length, [win(4)]));
    api.calls.last.complete(const LlmDone(tidied));
    await pump();
    expect(sends(port, sid), [
      [
        {'text': tidied}
      ]
    ]);
    expect(st.hint, 'A：已用 AI 整理并发出');
    // A failure goes on quietly (§8.1 D3): the original is sent, no word of the failure.
    st.remote[sid]!.composer.done(1, null);
    st.tidyOf(sid).begin(long, VoicePick.send);
    api.calls.last.complete(const LlmFailed('连不上 LLM 接入点'));
    await pump();
    expect(sends(port, sid).last, [
      {'text': long}
    ]);
    expect(st.hint, isNot(contains('失败')));
    st.tidyOf(sid).begin(long, VoicePick.edit);
    api.calls.last.complete(const LlmDone(tidied));
    await pump();
    expect(st.hint, 'A：AI 整理好了，放在写作面板里');
    st.dispose();
  });

  test('a letter typed on the picture while tidying stops it: the original goes in the panel first (§8.2)',
      () async {
    final (st, _) = await start();
    final rs = st.currentRemote!;
    st.tidyOf(sid).begin(long, VoicePick.send);
    rs.apply(ComposeKeyEvent(sid));
    expect(api.calls.single.cancelled, isTrue);
    expect(st.tidyOf(sid).phase, TidyPhase.idle);
    expect(rs.composer.open, isTrue);
    expect(rs.composer.draftText, long); // the letter comes after it, replayed into the editor
    expect(rs.composer.takeReplay(), isTrue);
    st.dispose();
  });

  test('the edit pick: the AI text opens in the panel over the original, one undo away (§8.2)', () async {
    final (st, _) = await start();
    final rs = st.currentRemote!;
    st.tidyOf(sid).begin(long, VoicePick.edit);
    api.calls.single.complete(const LlmDone(tidied));
    await pump();
    expect(rs.composer.open, isTrue);
    final e = FakeEditor();
    await rs.composer.attach(e);
    expect(e.value, tidied);
    expect(e.undoTo, long.trim());
    st.dispose();
  });

  test('a tidy in the session on show leaves the hint to the card', () async {
    final (st, _) = await start();
    final before = st.hint;
    st.tidyOf(sid).begin(long, VoicePick.send);
    api.calls.single.complete(const LlmDone(tidied));
    await pump();
    expect(st.hint, before);
    st.dispose();
  });

  test('closing the session keeps the original in its draft record', () async {
    final (st, port) = await start();
    st.tidyOf(sid).begin(long, VoicePick.send);
    st.endCurrent();
    port.emit(ClosedEvent(sid, 'rapp-client: quit'));
    await until(() => lines().isNotEmpty);
    final r = lines().single;
    expect(r['kind'], 'draft');
    expect(r['text'] as String, contains(long));
    expect(api.calls.single.cancelled, isTrue);
    expect(st.tidyIfAny(sid), isNull);
    st.dispose();
  });
}
