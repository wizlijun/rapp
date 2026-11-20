import 'dart:ui' show Rect;

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
  final thinks = <bool>[];
  final calls = <LlmCall>[];
  final texts = <void Function(String)?>[];
  void Function(String)? onText;

  @override
  LlmCall run(LlmEndpoint e, String app, String input,
      {Map<String, String>? vars, void Function(String text)? onText, Duration firstByte = const Duration(seconds: 10), bool think = false}) {
    runs.add((app, input));
    thinks.add(think);
    this.onText = onText;
    texts.add(onText);
    final c = LlmCall.manual();
    calls.add(c);
    return c;
  }
}

const long = '嗯那个我门明天下午三点开会';

/// Lets the microtasks run, then the AI's words come out to the last one.
void out(FakeAsync a, VoiceTidy t) {
  a.flushMicrotasks();
  while (t.writing) {
    a.elapse(const Duration(milliseconds: 16));
  }
}

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

  group('prefetch (边说边整理)', () {
    const heard = '嗯，那个我门明天下午三点开会。';

    test('a release with the same words takes it: no second call, its words show at once', () {
      fakeAsync((a) {
        final t = make();
        t.prefetch(long);
        expect(api.runs.single, ('dictation', long));
        expect(t.phase, TidyPhase.idle);
        api.texts.single!('我们明天');
        expect(t.shown, '');
        // The punctuation and white space aside, the release's words are the prefetch's.
        expect(t.begin(heard, VoicePick.send), isTrue);
        expect(api.runs, hasLength(1));
        expect(t.original, heard);
        out(a, t);
        expect(t.shown, '我们明天');
        api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
        out(a, t);
        a.elapse(const Duration(milliseconds: 1500));
        expect(sent.single.$2, '我们明天下午三点开会。');
        expect(sent.single.$3.ai, const VoiceAi(app: 'dictation', original: heard, result: '我们明天下午三点开会。'));
        expect(logs.where((l) => l.contains('prefetched')), hasLength(1));
        t.dispose();
      });
    });

    test('a prefetch already done is taken whole', () {
      fakeAsync((a) {
        final t = make();
        t.prefetch(long);
        api.texts.single!('我们明天下午三点开会。');
        api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
        a.flushMicrotasks();
        expect(t.begin(long, VoicePick.send), isTrue);
        out(a, t);
        expect(t.phase, TidyPhase.ready);
        expect(t.shown, '我们明天下午三点开会。');
        expect(api.runs, hasLength(1));
        t.dispose();
      });
    });

    test('a release with other words drops the prefetch and asks again', () {
      fakeAsync((a) {
        final t = make();
        t.prefetch(long);
        expect(t.begin('$long好吧', VoicePick.send), isTrue);
        expect(api.runs.map((r) => r.$2), [long, '$long好吧']);
        expect(api.calls.first.cancelled, isTrue);
        api.texts.first!('旧的');
        out(a, t);
        expect(t.shown, '');
        t.dispose();
      });
    });

    test('new words replace the prefetch; the same words again keep it', () {
      final t = make();
      t.prefetch(long);
      t.prefetch('$long。');
      expect(api.runs, hasLength(1));
      t.prefetch('$long好吧');
      expect(api.runs, hasLength(2));
      expect(api.calls.first.cancelled, isTrue);
      t.dispose();
      expect(api.calls.last.cancelled, isTrue);
    });

    test('null drops it; short words or not allowed start nothing', () {
      final t = make();
      t.prefetch('你好');
      allowed = false;
      t.prefetch(long);
      expect(api.runs, isEmpty);
      allowed = true;
      t.prefetch(long);
      t.prefetch(null);
      expect(api.calls.single.cancelled, isTrue);
      t.dispose();
    });

    test('a failed prefetch is not taken', () {
      fakeAsync((a) {
        final t = make();
        t.prefetch(long);
        api.calls.single.complete(const LlmFailed('LLM 出错'));
        a.flushMicrotasks();
        expect(t.begin(long, VoicePick.send), isTrue);
        expect(api.runs, hasLength(2));
        expect(t.phase, TidyPhase.tidying);
        t.dispose();
      });
    });
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

  test('done waits 1.5 s with the AI text, then sends it with its origin', () {
    fakeAsync((a) {
      final t = make();
      expect(t.begin(long, VoicePick.send), isTrue);
      expect(api.runs.single, ('dictation', long));
      expect(t.phase, TidyPhase.tidying);
      api.calls.single.complete(const LlmDone(' 我们明天下午三点开会。 '));
      out(a, t);
      // Time to click 编辑 (user 2026-11-20): nothing goes yet.
      expect(t.phase, TidyPhase.ready);
      expect(t.shown, '我们明天下午三点开会。');
      expect(sent, isEmpty);
      a.elapse(const Duration(milliseconds: 1499));
      expect(sent, isEmpty);
      a.elapse(const Duration(milliseconds: 1));
      expect(sent.single.$2, '我们明天下午三点开会。');
      expect(sent.single.$3.ai, const VoiceAi(app: 'dictation', original: long, result: '我们明天下午三点开会。'));
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('发送 while it waits sends the AI text at once', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      t.sendNow();
      expect(sent.single.$2, '我们明天下午三点开会。');
      expect(sent.single.$3.ai, isNotNull);
      expect(t.phase, TidyPhase.idle);
      a.elapse(const Duration(seconds: 3));
      expect(sent, hasLength(1));
      t.dispose();
    });
  });

  test('编辑 while it waits puts the AI text in the panel, marked', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      t.editNow();
      expect(edited.single, (1, '我们明天下午三点开会。', const VoiceAi(app: 'dictation', original: long, result: '我们明天下午三点开会。')));
      a.elapse(const Duration(seconds: 3));
      expect(sent, isEmpty);
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('a new press while it waits sends the AI text first', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      t.interrupt();
      expect(sent.single.$2, '我们明天下午三点开会。');
      expect(kept, isEmpty);
      a.elapse(const Duration(seconds: 3));
      expect(sent, hasLength(1));
      t.dispose();
    });
  });

  test('closing while it waits keeps the AI text, sends nothing', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      t.closed();
      expect(kept.single, (1, '我们明天下午三点开会。'));
      a.elapse(const Duration(seconds: 3));
      expect(sent, isEmpty);
      t.dispose();
    });
  });

  test('end while it waits hands back the AI text', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      expect(t.end(), '我们明天下午三点开会。');
      a.elapse(const Duration(seconds: 3));
      expect(sent, isEmpty);
      t.dispose();
    });
  });

  test('begin keeps where the voice bubble stood', () {
    final t = make();
    t.begin(long, VoicePick.send, at: const Rect.fromLTWH(10, 20, 300, 80));
    expect(t.at, const Rect.fromLTWH(10, 20, 300, 80));
    t.interrupt();
    t.begin(long, VoicePick.send);
    expect(t.at, isNull);
    t.dispose();
  });

  test('done on edit puts the AI text in the panel', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.edit);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      out(a, t);
      expect(sent, isEmpty);
      expect(edited.single.$2, '我们明天下午三点开会。');
      expect(edited.single.$3, const VoiceAi(app: 'dictation', original: long, result: '我们明天下午三点开会。'));
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('partial text shows as it comes', () {
    fakeAsync((a) {
    final t = make();
    var n = 0;
    t.addListener(() => n++);
    t.begin(long, VoicePick.send);
    expect(t.shown, '');
    final before = n;
    api.onText!('我们');
    a.elapse(const Duration(milliseconds: 100));
    expect(t.shown, '我们');
    expect(n, greaterThan(before));
    t.dispose();
    });
  });

  // The gateway thinks for seconds, then the whole answer lands in a fraction of a second (measured 2026-11-21):
  // shown as it lands it would read as "all at once". The words come out a few at a time instead.
  test('a burst of AI text comes out a few characters at a time', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      const all = '我们明天下午三点开会，把上周的数据带上。';
      api.onText!(all);
      a.flushMicrotasks();
      expect(t.shown.runes.length, lessThan(3));
      expect(t.writing, isTrue);
      a.elapse(const Duration(milliseconds: 200));
      expect(t.shown, isNotEmpty);
      expect(t.shown.runes.length, lessThan(all.runes.length));
      expect(all.startsWith(t.shown), isTrue);
      a.elapse(const Duration(milliseconds: 500));
      expect(t.shown, all);
      expect(t.writing, isFalse);
      t.dispose();
    });
  });

  test('even a long burst is all out within about 0.6 s', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      final all = '我们明天下午三点开会。' * 30;
      api.onText!(all);
      a.elapse(const Duration(milliseconds: 650));
      expect(t.shown, all);
      t.dispose();
    });
  });

  test('a done send starts its 1.5 s wait only once every word is out', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      const all = '我们明天下午三点开会，把上周的数据带上。';
      api.onText!(all);
      api.calls.single.complete(const LlmDone(all));
      a.flushMicrotasks();
      expect(t.phase, TidyPhase.ready);
      expect(t.writing, isTrue);
      a.elapse(const Duration(milliseconds: 1500));
      expect(sent, isEmpty);
      a.elapse(const Duration(milliseconds: 700));
      expect(sent.single.$2, all);
      t.dispose();
    });
  });

  test('done on edit puts the AI text in the panel once every word is out', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.edit);
      const all = '我们明天下午三点开会，把上周的数据带上。';
      api.calls.single.complete(const LlmDone(all));
      a.flushMicrotasks();
      expect(edited, isEmpty);
      expect(t.phase, TidyPhase.tidying);
      a.elapse(const Duration(milliseconds: 700));
      expect(edited.single.$2, all);
      expect(edited.single.$3, const VoiceAi(app: 'dictation', original: long, result: all));
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('发送 while an edit pick\'s words are still coming out sends the AI text', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.edit);
      const all = '我们明天下午三点开会，把上周的数据带上。';
      api.calls.single.complete(const LlmDone(all));
      a.flushMicrotasks();
      t.sendNow();
      expect(sent.single.$2, all);
      a.elapse(const Duration(seconds: 2));
      expect(edited, isEmpty);
      t.dispose();
    });
  });

  test('the tidy asks the AI to think only while the setting says so', () {
    var think = false;
    final t = VoiceTidy(
        sid: 1,
        endpoint: () => const LlmEndpoint(url: 'localhost:28001', key: 'k'),
        api: api,
        allowed: (_) => true,
        send: (_, _, _) => null,
        edit: (_, _, _) {},
        keep: (_, _) {},
        think: () => think);
    t.begin(long, VoicePick.send);
    t.interrupt();
    think = true;
    t.begin(long, VoicePick.send);
    expect(api.thinks, [false, true]);
    t.dispose();
  });

  test('a zero revealMax shows the words at once', () {
    final t = VoiceTidy(
        sid: 1,
        endpoint: () => const LlmEndpoint(url: 'localhost:28001', key: 'k'),
        api: api,
        allowed: (_) => true,
        send: (_, _, _) => null,
        edit: (_, _, _) {},
        keep: (_, _) {},
        revealMax: Duration.zero);
    t.begin(long, VoicePick.send);
    api.onText!('我们明天');
    expect(t.shown, '我们明天');
    expect(t.writing, isFalse);
    t.dispose();
  });

  test('a leading line break in the stream is not shown', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.onText!('\n\n我们');
      a.elapse(const Duration(milliseconds: 200));
      expect(t.shown, '我们');
      t.dispose();
    });
  });

  test('a failure on a send sends the original at once, as if never tidied (spec §8.1 D3)', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.onText!('我们明天');
      api.calls.single.complete(const LlmFailed('连不上 LLM 接入点', log: 'Connection refused'));
      a.flushMicrotasks();
      expect(sent.single.$2, long);
      expect(sent.single.$3.ai, isNull);
      expect(t.phase, TidyPhase.idle);
      expect(logs.where((l) => l.contains('failed Connection refused')), hasLength(1));
      a.elapse(const Duration(seconds: 60));
      expect(sent, hasLength(1));
      expect(kept, isEmpty);
      t.dispose();
    });
  });

  test('a failure on an edit puts the original in the panel, unmarked', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.edit);
      api.calls.single.complete(const LlmFailed('LLM 出错'));
      a.flushMicrotasks();
      expect(edited.single, (1, long, null));
      expect(sent, isEmpty);
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('a failure whose original cannot go shows the send hint a while', () {
    fakeAsync((a) {
      sendHint = voiceBusy;
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmFailed('LLM 出错'));
      a.flushMicrotasks();
      expect(sent.single.$2, long);
      expect(t.phase, TidyPhase.note);
      expect(t.note, voiceBusy);
      t.dispose();
    });
  });

  test('blank done is a failure: the original goes', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('  \n'));
      a.flushMicrotasks();
      expect(sent.single.$2, long);
      expect(sent.single.$3.ai, isNull);
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('还原 while a done send waits sends the original instead', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      t.restore();
      expect(sent.single.$2, long);
      expect(sent.single.$3.ai, isNull);
      expect(t.phase, TidyPhase.idle);
      a.elapse(const Duration(seconds: 3));
      expect(sent, hasLength(1));
      t.dispose();
    });
  });

  test('opening the original to compare holds a done send until a click', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      expect(t.comparing, isFalse);
      t.compare();
      expect(t.comparing, isTrue);
      a.elapse(const Duration(seconds: 10));
      expect(sent, isEmpty);
      expect(t.phase, TidyPhase.ready);
      t.sendNow();
      expect(sent.single.$2, '我们明天下午三点开会。');
      t.dispose();
    });
  });

  test('comparing while the AI writes: the done send waits too; a new tidy starts closed', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      t.compare();
      api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
      a.flushMicrotasks();
      a.elapse(const Duration(seconds: 10));
      expect(sent, isEmpty);
      t.sendNow();
      t.begin(long, VoicePick.send);
      expect(t.comparing, isFalse);
      t.dispose();
    });
  });

  test('还原 does nothing before the AI is done', () {
    final t = make();
    t.begin(long, VoicePick.send);
    t.restore();
    expect(sent, isEmpty);
    expect(t.phase, TidyPhase.tidying);
    t.dispose();
  });

  test('send original while tidying cancels and sends the original', () {
    final t = make();
    t.begin(long, VoicePick.send);
    t.sendNow();
    expect(api.calls.single.cancelled, isTrue);
    expect(sent.single.$2, long);
    expect(sent.single.$3.ai, isNull);
    expect(t.phase, TidyPhase.idle);
    t.dispose();
  });

  test('edit original while tidying', () {
    final t = make();
    t.begin(long, VoicePick.send);
    t.editNow();
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

  test('interrupt while a note shows just clears it', () {
    fakeAsync((a) {
      sendHint = voiceBusy;
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('好的。'));
      out(a, t);
      a.elapse(const Duration(milliseconds: 1500));
      expect(t.phase, TidyPhase.note);
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
      t.sendNow();
      c.complete(const LlmDone('迟到的结果'));
      a.flushMicrotasks();
      expect(sent.length, 1);
      expect(t.phase, TidyPhase.idle);
      t.dispose();
    });
  });

  test('the overall cap stops the call and sends the original', () {
    fakeAsync((a) {
      final t = make();
      t.begin(long, VoicePick.send);
      a.elapse(const Duration(milliseconds: 29999));
      expect(sent, isEmpty);
      a.elapse(const Duration(milliseconds: 1));
      expect(api.calls.single.cancelled, isTrue);
      expect(sent.single.$2, long);
      expect(sent.single.$3.ai, isNull);
      expect(t.phase, TidyPhase.idle);
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
      out(a, t);
      a.elapse(const Duration(milliseconds: 1500));
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
      out(a, t);
      a.elapse(const Duration(milliseconds: 1500));
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
      sendHint = voiceBusy;
      final t = make();
      t.begin(long, VoicePick.send);
      api.calls.single.complete(const LlmDone('好的。'));
      a.flushMicrotasks();
      a.elapse(const Duration(milliseconds: 1500));
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
