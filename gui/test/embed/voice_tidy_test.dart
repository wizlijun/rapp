import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_model.dart';
import 'package:rapp/embed/voice_button.dart' show voiceBusy;
import 'package:rapp/embed/voice_ring.dart' show VoicePick;
import 'package:rapp/embed/voice_tidy.dart';
import 'package:rapp/llm_api.dart';

/// Records each run and hands back a call the test completes.
class FakeLlmApi extends LlmApi {
  final runs = <(String app, String input)>[];
  final calls = <LlmCall>[];
  void Function(String)? onText;

  @override
  LlmCall run(LlmEndpoint e, String app, String input,
      {Map<String, String>? vars, void Function(String text)? onText, Duration firstByte = const Duration(seconds: 10)}) {
    runs.add((app, input));
    this.onText = onText;
    final c = LlmCall.manual();
    calls.add(c);
    return c;
  }
}

const long = '嗯那个我门明天下午三点开会';

void main() {
  late FakeLlmApi api;
  late bool allowed;
  late List<(Object, String, VoiceOrigin)> sent;
  late List<(Object, String, VoiceAi?)> edited;
  late List<(Object, String)> kept;
  late List<String> logs;
  String? sendHint;

  VoiceTidy make() => VoiceTidy(
        sid: 1,
        endpoint: () => const LlmEndpoint(url: 'localhost:28001', key: 'k'),
        api: api,
        allowed: (_) => allowed,
        send: (sid, t, v) {
          sent.add((sid, t, v));
          return sendHint;
        },
        edit: (sid, t, ai) => edited.add((sid, t, ai)),
        keep: (sid, t) => kept.add((sid, t)),
        log: logs.add,
      );

  setUp(() {
    api = FakeLlmApi();
    allowed = true;
    sent = [];
    edited = [];
    kept = [];
    logs = [];
    sendHint = null;
  });

  test('long counts non-space characters', () {
    expect(VoiceTidy.long('一二三四五六七八九十'), isFalse);
    expect(VoiceTidy.long('一二三四五六七八九十一'), isTrue);
    expect(VoiceTidy.long('一 二 三 四 五 六 七 八 九 十'), isFalse);
  });

  test('short or not allowed is declined', () {
    final t = make();
    expect(t.begin('你好', VoicePick.send), isFalse);
    allowed = false;
    expect(t.begin(long, VoicePick.send), isFalse);
    expect(api.runs, isEmpty);
    expect(t.phase, TidyPhase.idle);
    t.dispose();
  });

  test('done sends the AI text with its origin', () {
    fakeAsync((a) {
      final t = make();
      expect(t.begin(long, VoicePick.send), isTrue);
      expect(api.runs.single, ('dictation', long));
      expect(t.phase, TidyPhase.tidying);
      api.calls.single.complete(const LlmDone(' 我们明天下午三点开会。 '));
      a.flushMicrotasks();
      expect(sent.single.$2, '我们明天下午三点开会。');
      expect(sent.single.$3.ai, const VoiceAi(app: 'dictation', original: long, result: '我们明天下午三点开会。'));
      expect(t.phase, TidyPhase.note);
      expect(t.note, '已用 AI 整理');
      a.elapse(const Duration(milliseconds: 1500));
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('done on edit puts the AI text in the panel', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.edit);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      expect(sent, isEmpty);
      expect(edited.single.$2, '我们明天下午三点开会。');
      expect(edited.single.$3, const VoiceAi(app: 'dictation', original: long, result: '我们明天下午三点开会。'));
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('partial text shows as it comes', () {
    final t = make();
    var n = 0;
    t.addListener(() => n++);
    t.begin(long, VoicePick.send);
    expect(t.shown, '');
    final before = n;
    api.onText!('我们');
    expect(t.shown, '我们');
    expect(n, greaterThan(before));
    t.dispose();
  });

  test('failure stops and waits', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmFailed('连不上 LLM 接入点', log: 'Connection refused'));
      a.flushMicrotasks();
      expect(t.phase, TidyPhase.failed);
      expect(t.reason, '连不上 LLM 接入点');
      a.elapse(const Duration(seconds: 60));
      expect(sent, isEmpty);
      expect(kept, isEmpty);
      expect(t.phase, TidyPhase.failed);
      t.dispose();
    });
  });

  test('blank done is a failure', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('  \n'));
      a.flushMicrotasks();
      expect(t.phase, TidyPhase.failed);
      expect(t.reason, 'AI 没有给出结果');
      expect(sent, isEmpty);
      t.dispose();
    });
  });

  test('send original while tidying cancels and sends the original', () {
    final t = make();
    t.begin(long, VoicePick.send);
    t.sendOriginal();
    expect(api.calls.single.cancelled, isTrue);
    expect(sent.single.$2, long);
    expect(sent.single.$3.ai, isNull);
    expect(t.phase, TidyPhase.idle);
    t.dispose();
  });

  test('send original after a failure sends the original', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmFailed('LLM 出错'));
      a.flushMicrotasks();
      t.sendOriginal();
      expect(sent.single.$2, long);
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('edit original while tidying', () {
    final t = make();
    t.begin(long, VoicePick.send);
    t.editOriginal();
    expect(api.calls.single.cancelled, isTrue);
    expect(edited.single, (1, long, null));
    expect(t.phase, TidyPhase.idle);
    t.dispose();
  });

  test('interrupt while tidying keeps the original, sends nothing', () {
    final t = make();
    t.begin(long, VoicePick.send);
    t.interrupt();
    expect(api.calls.single.cancelled, isTrue);
    expect(kept.single, (1, long));
    expect(sent, isEmpty);
    expect(t.phase, TidyPhase.idle);
    t.dispose();
  });

  test('interrupt while failed keeps the original, sends nothing', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmFailed('LLM 出错'));
      a.flushMicrotasks();
      t.interrupt();
      expect(kept.single, (1, long));
      expect(sent, isEmpty);
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('interrupt while a note shows just clears it', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('好的。'));
      a.flushMicrotasks();
      t.interrupt();
      expect(t.phase, TidyPhase.idle);
      expect(kept, isEmpty);
      t.dispose();
    });
  });

  test('a result after the user chose is ignored', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      final c = api.calls.single;
      t.sendOriginal();
      c.complete(const LlmDone('迟到的结果'));
      a.flushMicrotasks();
      expect(sent.length, 1);
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('the overall cap fails the tidy', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      a.elapse(const Duration(seconds: 30));
      expect(api.calls.single.cancelled, isTrue);
      expect(t.phase, TidyPhase.failed);
      expect(t.reason, 'LLM 没有及时回应');
      expect(sent, isEmpty);
      t.dispose();
    });
  });

  test('moveTo sends the result to the new sid', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      t.moveTo(2);
      expect(t.sid, 2);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      expect(sent.single.$1, 2);
      t.dispose();
    });
  });

  test('closed keeps the original', () {
    final t = make();
    t.begin(long, VoicePick.send);
    t.closed();
    expect(kept.single, (1, long));
    expect(api.calls.single.cancelled, isTrue);
    t.dispose();
  });

  test('done while busy keeps the AI text and notes the hint', () {
    fakeAsync((a) {
      sendHint = voiceBusy;
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      expect(t.phase, TidyPhase.note);
      expect(t.note, voiceBusy);
      a.elapse(const Duration(milliseconds: 1900));
      expect(t.phase, TidyPhase.note);
      a.elapse(const Duration(milliseconds: 200));
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('a new begin drops a pending note', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('好的。'));
      a.flushMicrotasks();
      expect(t.begin(long, VoicePick.send), isTrue);
      expect(t.phase, TidyPhase.tidying);
      expect(t.note, isNull);
      t.dispose();
    });
  });

  test('log lines carry no text', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.onText!('我们明天');
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      t.begin(long, VoicePick.send);
      api.calls.last.complete(const LlmFailed('LLM 出错', log: '500 x'));
      a.flushMicrotasks();
      expect(logs, isNotEmpty);
      for (final l in logs) {
        expect(l, isNot(contains('明天')));
        expect(l, isNot(contains('开会')));
      }
      t.dispose();
    });
  });
}
