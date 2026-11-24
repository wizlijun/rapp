import 'dart:ui' show Rect;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/composer_model.dart';
import 'package:rapp/embed/tidy_diff.dart';
import 'package:rapp/embed/tidy_mode.dart';
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
  late List<List<LearnItem>> learned;
  String? sendHint;

  var mode = TidyMode.prompt;
  late List<TidyMode> setModes;

  bool Function(String observed, String avoid)? fromVocabulary;
  late List<(Object, String?)> helds;

  VoiceTidy make({bool learn = true}) => VoiceTidy(
        fromVocabulary: fromVocabulary,
        held: (sid, o) => helds.add((sid, o)),
        mode: (_) => mode,
        setMode: (sid, m) {
          mode = m;
          setModes.add(m);
        },
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
        learn: learn ? (sid, items) => learned.add(items) : null,
      );

  setUp(() {
    api = FakeLlmApi();
    allowed = true;
    sent = [];
    edited = [];
    kept = [];
    logs = [];
    learned = [];
    sendHint = null;
    mode = TidyMode.prompt;
    setModes = [];
    fromVocabulary = null;
    helds = [];
  });

  group('heard and fixed words (本机纠词, spec D6/D9)', () {
    const heard = '打开拍森跑一下这个测试脚本吧';
    const fixed = '打开Python跑一下这个测试脚本吧';

    test('the heard words are the original line and the diff base', () {
      fakeAsync((a) {
        final t = make();
        t.begin(fixed, VoicePick.send, heard: heard);
        expect(api.runs.single.$2, fixed); // the AI tidies the fixed words
        expect(t.original, fixed);
        expect(t.heard, heard);
        api.calls.single.complete(const LlmDone(fixed));
        out(a, t);
        expect(t.changes.map((c) => (c.before, c.after)), [('拍森', 'Python')]);
        expect(t.text, fixed);
        a.elapse(const Duration(milliseconds: 1500));
        expect(sent.single.$2, fixed);
        expect(sent.single.$3.ai!.original, heard);
        expect(sent.single.$3.ai!.result, fixed);
        t.dispose();
      });
    });

    test('tidy failure sends the fixed text', () {
      fakeAsync((a) {
        final t = make();
        t.begin(fixed, VoicePick.send, heard: heard);
        api.calls.single.complete(const LlmFailed('连不上 LLM 接入点', log: 'Connection refused'));
        a.flushMicrotasks();
        expect(sent.single.$2, fixed);
        expect(sent.single.$3.ai, isNull);
        expect(sent.single.$3.heard!.heard, heard);
        expect(sent.single.$3.heard!.fixed, fixed);
        t.dispose();
      });
    });

    test('a timeout sends the fixed text too; an edit pick puts it in the panel', () {
      fakeAsync((a) {
        final t = make();
        t.begin(fixed, VoicePick.send, heard: heard);
        a.elapse(const Duration(seconds: 31));
        expect(sent.single.$2, fixed);
        expect(sent.single.$3.heard!.heard, heard);
        t.begin(fixed, VoicePick.edit, heard: heard);
        api.calls.last.complete(const LlmFailed('LLM 出错'));
        a.flushMicrotasks();
        expect(edited.single, (1, fixed, null));
        t.dispose();
      });
    });

    test('sendNow and restore send the fixed text', () {
      fakeAsync((a) {
        final t = make();
        t.begin(fixed, VoicePick.send, heard: heard);
        t.sendNow();
        expect(sent.single.$2, fixed);
        expect(sent.single.$3.ai, isNull);
        expect(sent.single.$3.heard!.heard, heard);
        expect(sent.single.$3.heard!.fixed, fixed);
        t.begin(fixed, VoicePick.send, heard: heard);
        api.calls.last.complete(const LlmDone('打开Python跑一下这个测试脚本。'));
        a.flushMicrotasks();
        t.restore();
        expect(sent, hasLength(2));
        expect(sent.last.$2, fixed);
        expect(sent.last.$3.ai, isNull);
        expect(sent.last.$3.heard!.heard, heard);
        t.dispose();
      });
    });

    test('edit, close, end and held keep the fixed text', () {
      fakeAsync((a) {
        final t = make();
        t.begin(fixed, VoicePick.send, heard: heard);
        expect(helds.last, (1, fixed));
        t.editNow();
        expect(edited.single, (1, fixed, null));
        t.begin(fixed, VoicePick.send, heard: heard);
        t.closed();
        expect(kept.single, (1, fixed));
        t.begin(fixed, VoicePick.send, heard: heard);
        expect(t.end(), fixed);
        t.dispose();
      });
    });

    test('without heard, the original is both', () {
      fakeAsync((a) {
        final t = make();
        t.begin(fixed, VoicePick.send);
        expect(t.heard, fixed);
        api.calls.single.complete(const LlmDone(fixed));
        out(a, t);
        expect(t.changes, isEmpty);
        t.dispose();
      });
    });

    test('prefetch keyed by the fixed text hits', () {
      fakeAsync((a) {
        final t = make();
        t.prefetch(fixed);
        expect(api.runs, hasLength(1));
        t.begin(fixed, VoicePick.send, heard: heard);
        expect(api.runs, hasLength(1));
        t.dispose();
      });
    });

    test('flipping a learned fix offers preserve', () {
      fakeAsync((a) {
        fromVocabulary = (o, v) => false;
        final t = make();
        t.begin(fixed, VoicePick.send, heard: heard);
        api.calls.single.complete(const LlmDone(fixed));
        out(a, t);
        t.flip(0);
        expect(t.text, heard);
        expect(t.offer!.items.single, LearnItem.preserve(observed: '拍森', avoid: 'Python', excerpt: heard));
        expect(t.flipHint, isNull);
        t.dispose();
      });
    });

    test('flipping a vocabulary fix only hints', () {
      fakeAsync((a) {
        final asked = <(String, String)>[];
        fromVocabulary = (o, v) {
          asked.add((o, v));
          return true;
        };
        final t = make();
        t.begin(fixed, VoicePick.send, heard: heard);
        api.calls.single.complete(const LlmDone(fixed));
        out(a, t);
        t.flip(0);
        expect(asked, [('拍森', 'Python')]);
        expect(t.text, heard); // this once it goes as heard
        expect(t.offer, isNull);
        expect(t.flipHint, '这条在正式词表里，要改请去 note.md');
        t.flip(0);
        expect(t.flipHint, isNull);
        t.flip(0);
        expect(t.flipHint, isNotNull);
        t.sendNow();
        expect(t.flipHint, isNull);
        expect(learned, isEmpty);
        t.dispose();
      });
    });

    test('a vocabulary hint gives way to a learned flip, and back', () {
      fakeAsync((a) {
        fromVocabulary = (o, v) => o == '拍森';
        final t = make();
        t.begin('打开拍森跑一下黑猫瑞这个测试', VoicePick.send);
        api.calls.single.complete(const LlmDone('打开Python跑一下Hemory这个测试'));
        out(a, t);
        t.flip(1);
        expect(t.offer!.items.single.observed, '黑猫瑞');
        t.flip(0); // the hint takes the bubble's line
        expect(t.offer, isNull);
        expect(t.flipHint, isNotNull);
        t.flip(1); // flipping another back leaves it
        expect(t.flipHint, isNotNull);
        t.flip(1); // a learned flip takes the line again
        expect(t.flipHint, isNull);
        expect(t.offer!.items.single.observed, '黑猫瑞');
        t.dispose();
      });
    });
  });

  group('tidy mode (按用途整理)', () {
    test("the tidy runs the session's mode", () {
      fakeAsync((a) {
        mode = TidyMode.chat;
        final t = make();
        t.begin(long, VoicePick.send);
        expect(api.runs.single.$1, 'dictation-chat');
        expect(t.running, TidyMode.chat);
        api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
        out(a, t);
        a.elapse(const Duration(milliseconds: 1500));
        expect(sent.single.$3.ai!.app, 'dictation-chat');
        expect(logs.any((l) => l.contains('dictation-chat')), isTrue);
        t.dispose();
      });
    });

    test('switchMode re-tidies the original with the other mode and saves it', () {
      fakeAsync((a) {
        mode = TidyMode.chat;
        final t = make();
        t.begin(long, VoicePick.send);
        api.calls.single.complete(const LlmDone('我们明天下午三点开会。'));
        out(a, t);
        expect(t.phase, TidyPhase.ready);
        expect(t.changes, isNotEmpty);
        t.switchMode();
        expect(api.runs.last, ('dictation', long));
        expect(setModes, [TidyMode.prompt]);
        expect(t.running, TidyMode.prompt);
        expect(t.changes, isEmpty);
        expect(t.phase, TidyPhase.tidying);
        expect(t.shown, '');
        a.elapse(const Duration(seconds: 5));
        expect(sent, isEmpty);
        api.calls.last.complete(const LlmDone('明天下午三点开会'));
        out(a, t);
        a.elapse(const Duration(milliseconds: 1500));
        expect(sent.single.$3.ai!.app, 'dictation');
        t.dispose();
      });
    });

    test('switchMode drops an in-bubble offer, keeps a standalone box, and restarts the timer', () {
      fakeAsync((a) {
        final t = make();
        t.begin(long, VoicePick.send);
        a.elapse(const Duration(seconds: 25));
        t.offerLearn([LearnItem.preserve(observed: 'a', avoid: 'b', excerpt: 'c')]);
        t.switchMode();
        expect(t.offer, isNotNull); // standalone survives
        a.elapse(const Duration(seconds: 25)); // 50 s since start, 25 s since the switch
        expect(t.phase, TidyPhase.tidying);
        a.elapse(const Duration(seconds: 6));
        expect(sent.single.$2, long);
        t.dispose();
      });
    });

    test('a switch after a flip settles normally and sends the new result', () {
      fakeAsync((a) {
        final t = make();
        t.begin('明天用拍森跑一下黑猫瑞', VoicePick.send);
        api.calls.single.complete(const LlmDone('明天用Python跑一下Hemory'));
        out(a, t);
        t.flip(0);
        expect(t.stopped, isTrue);
        t.switchMode();
        expect(t.stopped, isFalse);
        api.calls.last.complete(const LlmDone('明天用Python跑一下Hemory。'));
        out(a, t);
        a.elapse(const Duration(milliseconds: 1500));
        expect(sent.single.$2, '明天用Python跑一下Hemory。');
        t.dispose();
      });
    });

    test('canSwitch is false while comparing', () {
      fakeAsync((a) {
        final t = make();
        t.begin(long, VoicePick.send);
        expect(t.canSwitch, isTrue);
        t.compare();
        expect(t.canSwitch, isFalse);
        t.dispose();
      });
    });

    test('a prefetch in the other mode is not used', () {
      fakeAsync((a) {
        final t = make();
        t.prefetch(long);
        expect(api.runs.single, ('dictation', long));
        mode = TidyMode.chat;
        t.begin(long, VoicePick.send);
        expect(api.runs, hasLength(2));
        expect(api.runs.last, ('dictation-chat', long));
        expect(api.calls.first.cancelled, isTrue);
        t.dispose();
      });
    });
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

  group('flip an AI change back (切换词)', () {
    const heard = '明天用拍森跑一下黑猫瑞';
    const ai = '明天用Python跑一下Hemory';

    // A done send whose words are all out.
    VoiceTidy ready(FakeAsync a, {bool learn = true, VoicePick pick = VoicePick.send}) {
      final t = make(learn: learn);
      t.begin(heard, pick);
      api.calls.single.complete(const LlmDone(ai));
      out(a, t);
      return t;
    }

    test('a done send lists the AI\'s changes', () {
      fakeAsync((a) {
        final t = ready(a);
        expect(t.changes.map((c) => c.before), ['拍森', '黑猫瑞']);
        expect(t.changes.map((c) => c.after), ['Python', 'Hemory']);
        expect(t.flipped(0), isFalse);
        expect(t.text, ai);
        t.dispose();
      });
    });

    test('flip holds the send and sends the flipped text', () {
      fakeAsync((a) {
        final t = ready(a);
        t.flip(1);
        expect(t.flipped(1), isTrue);
        expect(t.stopped, isTrue);
        expect(t.text, '明天用Python跑一下黑猫瑞');
        a.elapse(const Duration(seconds: 5));
        expect(sent, isEmpty);
        expect(t.phase, TidyPhase.ready);
        t.sendNow();
        expect(sent.single.$2, '明天用Python跑一下黑猫瑞');
        expect(sent.single.$3.ai!.result, ai);
        expect(t.changes, isEmpty);
        t.dispose();
      });
    });

    test('flip builds the text by rune offsets past an emoji', () {
      fakeAsync((a) {
        final t = make();
        t.begin('😀明天用拍森跑一下黑猫瑞', VoicePick.send);
        api.calls.single.complete(const LlmDone('😀明天用Python跑一下Hemory'));
        out(a, t);
        t.flip(0);
        expect(t.text, '😀明天用拍森跑一下Hemory');
        t.dispose();
      });
    });

    test('edit after a flip puts the flipped text in the panel, ai.result unchanged', () {
      fakeAsync((a) {
        final t = ready(a);
        t.flip(0);
        t.editNow();
        expect(edited.single.$2, '明天用拍森跑一下Hemory');
        expect(edited.single.$3!.result, ai);
        expect(edited.single.$3!.original, heard);
        t.dispose();
      });
    });

    test('flip before the words are out does nothing', () {
      fakeAsync((a) {
        final t = make();
        t.begin(heard, VoicePick.send);
        t.flip(0);
        expect(t.stopped, isFalse);
        api.calls.single.complete(const LlmDone(ai));
        a.flushMicrotasks();
        expect(t.writing, isTrue);
        t.flip(0);
        expect(t.flipped(0), isFalse);
        expect(t.stopped, isFalse);
        expect(t.offer, isNull);
        t.dispose();
      });
    });

    test('a flip on a long original offers preserve with a clipped excerpt', () {
      fakeAsync((a) {
        final pad = '天地玄黄' * 100;
        final h = '$pad拍森跑一下$pad', r = '${pad}Python跑一下$pad';
        final t = make(learn: true);
        t.begin(h, VoicePick.send);
        api.calls.single.complete(LlmDone(r));
        out(a, t);
        t.flip(0);
        final item = t.offer!.items.single;
        expect(item.observed, '拍森');
        expect(item.excerpt.runes.length, lessThanOrEqualTo(2000));
        expect(item.excerpt.runes.length, lessThan(h.runes.length));
        expect(item.excerpt, contains('拍森'));
        t.dispose();
      });
    });

    test('flipping back to the heard words offers preserve; flipping again takes it away', () {
      fakeAsync((a) {
        final t = ready(a);
        t.flip(1);
        final o = t.offer!;
        expect(o.items.single, LearnItem.preserve(observed: '黑猫瑞', avoid: 'Hemory', excerpt: heard));
        expect(o.inBubble, isTrue);
        expect(o.done, isFalse);
        t.flip(1);
        expect(t.offer, isNull);
        expect(t.stopped, isTrue);
        t.dispose();
      });
    });

    test('flipping another change replaces the offer', () {
      fakeAsync((a) {
        final t = ready(a);
        t.flip(0);
        t.flip(1);
        expect(t.offer!.items.single.observed, '黑猫瑞');
        t.flip(1);
        expect(t.offer, isNull);
        t.dispose();
      });
    });

    test('remember sends the picked items once and shows done', () {
      fakeAsync((a) {
        final t = ready(a);
        t.flip(1);
        t.remember();
        expect(learned.single.single, LearnItem.preserve(observed: '黑猫瑞', avoid: 'Hemory', excerpt: heard));
        expect(t.offer!.done, isTrue);
        t.remember();
        expect(learned, hasLength(1));
        a.elapse(const Duration(milliseconds: 1400));
        expect(t.offer, isNotNull);
        a.elapse(const Duration(milliseconds: 200));
        expect(t.offer, isNull);
        t.dispose();
      });
    });

    test('no learn callback, no offer', () {
      fakeAsync((a) {
        final t = ready(learn: false, a);
        t.flip(1);
        expect(t.flipped(1), isTrue);
        expect(t.offer, isNull);
        t.offerLearn([const LearnItem.replace(observed: 'a', output: 'b', excerpt: 'x')]);
        expect(t.offer, isNull);
        t.remember();
        expect(learned, isEmpty);
        t.dispose();
      });
    });

    test('sending with an open bubble offer moves it to the 8 s box', () {
      fakeAsync((a) {
        final t = ready(a);
        t.flip(1);
        t.sendNow();
        expect(t.offer!.inBubble, isFalse);
        expect(t.offer!.items.single.observed, '黑猫瑞');
        a.elapse(const Duration(seconds: 7));
        expect(t.offer, isNotNull);
        a.elapse(const Duration(seconds: 1));
        expect(t.offer, isNull);
        expect(learned, isEmpty);
        t.dispose();
      });
    });

    test('closing the bubble drops its open offer', () {
      fakeAsync((a) {
        final t = ready(a);
        t.flip(1);
        t.closed();
        expect(t.offer, isNull);
        expect(kept.single.$2, '明天用Python跑一下黑猫瑞');
        t.dispose();
      });
    });

    test('offerLearn: at most 3, all picked, gone after 8 s; a new begin keeps it', () {
      fakeAsync((a) {
        final t = make();
        final items = [for (var i = 0; i < 5; i++) LearnItem.replace(observed: 'o$i', output: 'p$i', excerpt: heard)];
        t.offerLearn(items);
        expect(t.offer!.items, hasLength(3));
        expect(t.offer!.picked, {0, 1, 2});
        expect(t.offer!.inBubble, isFalse);
        t.togglePick(1);
        expect(t.offer!.picked, {0, 2});
        t.begin(heard, VoicePick.send);
        expect(t.offer, isNotNull);
        a.elapse(const Duration(seconds: 7));
        expect(t.offer, isNotNull);
        a.elapse(const Duration(seconds: 1));
        expect(t.offer, isNull);
        t.dispose();
      });
    });

    test('offerLearn remember sends only the picked ones; dismiss clears', () {
      fakeAsync((a) {
        final t = make();
        t.offerLearn([for (var i = 0; i < 2; i++) LearnItem.replace(observed: 'o$i', output: 'p$i', excerpt: heard)]);
        t.togglePick(0);
        t.remember();
        expect(learned.single.map((i) => i.observed), ['o1']);
        a.elapse(const Duration(seconds: 2));
        t.offerLearn([const LearnItem.replace(observed: 'a', output: 'b', excerpt: heard)]);
        t.dismissOffer();
        expect(t.offer, isNull);
        t.dispose();
      });
    });

    test('an edit pick computes no changes', () {
      fakeAsync((a) {
        final t = ready(a, pick: VoicePick.edit);
        expect(t.changes, isEmpty);
        t.flip(0);
        expect(t.stopped, isFalse);
        t.dispose();
      });
    });

    test('the log carries events and milliseconds, never words', () {
      fakeAsync((a) {
        final t = ready(a);
        t.flip(1);
        t.remember();
        t.sendNow();
        for (final l in logs) {
          expect(l, isNot(contains('黑猫瑞')));
          expect(l, isNot(contains('Hemory')));
        }
        expect(logs.where((l) => l.contains('flip')), isNotEmpty);
        t.dispose();
      });
    });
  });
}
