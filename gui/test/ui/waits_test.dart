import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/waits.dart';

const _new = '正在新建终端…';

void main() {
  late Waits w;

  Waits make(FakeAsync a) => Waits(now: () => DateTime(2026).add(a.elapsed));

  test('hidden_before_300ms: a wait done in 100 ms never shows', () {
    fakeAsync((a) {
      w = make(a);
      var everShown = false;
      w.addListener(() => everShown |= w.shown.isNotEmpty);
      unawaited(w.run(_new, () => Future<void>.delayed(const Duration(milliseconds: 100))));
      a.elapse(const Duration(milliseconds: 50));
      expect(w.shown, isEmpty);
      a.elapse(const Duration(seconds: 1));
      expect(w.shown, isEmpty);
      expect(w.outcome, isNull);
      expect(everShown, isFalse);
    });
  });

  test('shown_after_300ms: a wait still going at 300 ms shows', () {
    fakeAsync((a) {
      w = make(a);
      unawaited(w.run(_new, () => Completer<void>().future, detail: 'mbp'));
      a.elapse(const Duration(milliseconds: 299));
      expect(w.shown, isEmpty);
      a.elapse(const Duration(milliseconds: 1));
      expect(w.shown.single.what, _new);
      expect(w.shown.single.detail, 'mbp');
      expect(w.shown.single.started, DateTime(2026));
    });
  });

  test('failure_outcome_stays_4s: the words show for 4 s and the error goes on', () {
    fakeAsync((a) {
      w = make(a);
      Object? thrown;
      w.run(_new, () async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw StateError('x');
      }, words: (_) => 'w').then((_) {}, onError: (Object e) {
        thrown = e;
      });
      a.elapse(const Duration(milliseconds: 60));
      expect(thrown, isA<StateError>());
      expect(w.outcome!.text, 'w');
      expect(w.outcome!.asks, isFalse);
      expect(w.shown, isEmpty);
      a.elapse(const Duration(milliseconds: 3840));
      expect(w.outcome, isNotNull);
      a.elapse(const Duration(milliseconds: 200));
      expect(w.outcome, isNull);
    });
  });

  test('ask_outcome_stays_8s: a permission ask shows for 8 s', () {
    fakeAsync((a) {
      w = make(a);
      w.run(_new, () => Future<void>.error(StateError('x')), asks: (_) => true).ignore();
      a.flushMicrotasks();
      expect(w.outcome!.asks, isTrue);
      expect(w.outcome!.text, 'Bad state: x');
      a.elapse(const Duration(milliseconds: 7900));
      expect(w.outcome, isNotNull);
      a.elapse(const Duration(milliseconds: 200));
      expect(w.outcome, isNull);
    });
  });

  test('outcome_and_waiting_together: a failure and the one still waiting both show', () {
    fakeAsync((a) {
      w = make(a);
      w.run(_new, () => Future<void>.delayed(const Duration(milliseconds: 500), () => throw StateError('x'))).ignore();
      unawaited(w.run(_new, () => Completer<void>().future));
      a.elapse(const Duration(milliseconds: 600));
      expect(w.outcome, isNotNull);
      expect(w.shown, hasLength(1));
      expect(w.moreLine, isNull);
      unawaited(w.run('正在恢复终端…', () => Completer<void>().future));
      a.elapse(const Duration(milliseconds: 400));
      expect(w.shown.first.what, _new);
      expect(w.moreLine, '另有 1 件在等');
    });
  });

  test('queued_line: three of the same kind say 还有 2 个排队', () {
    fakeAsync((a) {
      w = make(a);
      for (var i = 0; i < 3; i++) {
        unawaited(w.run(_new, () => Completer<void>().future));
      }
      a.elapse(const Duration(milliseconds: 300));
      expect(w.shown, hasLength(3));
      expect(w.moreLine, '还有 2 个排队');
    });
  });

  test('dispose_cancels_timers: no notify after dispose', () {
    fakeAsync((a) {
      w = make(a);
      final done = Completer<void>();
      w.run(_new, () => done.future).ignore();
      w.run(_new, () => Future<void>.error(StateError('x'))).ignore();
      a.flushMicrotasks();
      expect(w.outcome, isNotNull);
      w.dispose();
      done.complete();
      a.elapse(const Duration(seconds: 10));
      a.flushMicrotasks();
    });
  });
}
