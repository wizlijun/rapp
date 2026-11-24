import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/voice_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rapp/speech');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  void mock(Future<Object?> Function(MethodCall) reply) {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (c) {
      calls.add(c.method);
      return reply(c);
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<Object?> ok(MethodCall c) async => c.method == 'start' ? 'ok' : null;

  test('start hands the hotwords to native, none when there are none', () async {
    final args = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'start') args.add(c.arguments);
      return c.method == 'start' ? 'ok' : null;
    });
    final v = VoiceInput();
    addTearDown(v.dispose);
    await v.start();
    await v.cancel();
    v.hotwords = () => ['Dify', 'Lovable'];
    await v.start();
    await v.cancel();
    expect(args, [
      null,
      {
        'hotwords': ['Dify', 'Lovable']
      }
    ]);
  });

  test('start ok -> listening; partials update text', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    expect(await v.start(), VoiceStart.ok);
    expect(v.phase, VoicePhase.listening);
    await v.handle(const MethodCall('partial', {'text': '你'}));
    expect(v.text, '你');
  });

  test('stop resolves with the final text', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    await v.start();
    final f = v.stop();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start', 'stop']);
    expect(v.phase, VoicePhase.finishing);
    await v.handle(const MethodCall('final', {'text': '你好'}));
    expect(await f, '你好');
    expect(v.phase, VoicePhase.idle);
  });

  test('stop falls back to the last partial after 1 s', () {
    fakeAsync((fa) {
      mock(ok);
      final v = VoiceInput();
      v.start();
      fa.flushMicrotasks();
      v.handle(const MethodCall('partial', {'text': '你好'}));
      String? got;
      v.stop().then((t) => got = t);
      fa.flushMicrotasks();
      expect(got, isNull);
      fa.elapse(const Duration(seconds: 1));
      expect(got, '你好');
      expect(v.phase, VoicePhase.idle);
      v.dispose();
    });
  });

  test('cancel clears and calls native cancel', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    await v.start();
    await v.handle(const MethodCall('partial', {'text': '你'}));
    await v.cancel();
    expect(calls, ['start', 'cancel']);
    expect(v.text, '');
    expect(v.phase, VoicePhase.idle);
  });

  test('5 minutes fires onMaxLength once, not at the old 60 s', () {
    fakeAsync((fa) {
      mock(ok);
      final v = VoiceInput();
      var n = 0;
      v.onMaxLength = () => n++;
      v.start();
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 61));
      expect(n, 0);
      fa.elapse(const Duration(minutes: 3, seconds: 58)); // 4:59 in total
      expect(n, 0);
      fa.elapse(const Duration(minutes: 3));
      expect(n, 1);
      v.dispose();
    });
  });

  test('error goes idle and reports the code', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    String? code;
    v.onError = (c) => code = c;
    await v.start();
    await v.handle(const MethodCall('error', {'code': 'interrupted'}));
    expect(code, 'interrupted');
    expect(v.phase, VoicePhase.idle);
  });

  test('a stop before start answers cancels and gives empty text', () async {
    final gate = Completer<Object?>();
    mock((c) => c.method == 'start' ? gate.future : Future.value(null));
    final v = VoiceInput();
    addTearDown(v.dispose);
    final s = v.start();
    await Future<void>.delayed(Duration.zero);
    expect(v.phase, VoicePhase.starting);
    final f = v.stop();
    gate.complete('ok');
    // Aborted: silent, whatever native answered.
    expect(await s, VoiceStart.cancelled);
    expect(await f, '');
    expect(calls, ['start', 'cancel']);
    expect(v.phase, VoicePhase.idle);
  });

  test('a late final, partial or level from the last run while starting is not used by the next stop', () async {
    final gate = Completer<Object?>();
    mock((c) => c.method == 'start' ? gate.future : Future.value(null));
    final v = VoiceInput();
    addTearDown(v.dispose);
    final s = v.start();
    await Future<void>.delayed(Duration.zero);
    expect(v.phase, VoicePhase.starting);
    await v.handle(const MethodCall('final', {'text': '旧的'}));
    await v.handle(const MethodCall('partial', {'text': '旧'}));
    await v.handle(const MethodCall('level', {'value': .5}));
    expect(v.text, '');
    expect(v.level.value, 0);
    gate.complete('ok');
    expect(await s, VoiceStart.ok);
    final f = v.stop();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start', 'stop']);
    expect(v.phase, VoicePhase.finishing);
    await v.handle(const MethodCall('final', {'text': '新的'}));
    expect(await f, '新的');
  });

  test('cancel while starting calls native cancel at once, before start answers', () async {
    final gate = Completer<Object?>();
    mock((c) => c.method == 'start' ? gate.future : Future.value(null));
    final v = VoiceInput();
    addTearDown(v.dispose);
    final s = v.start();
    await Future<void>.delayed(Duration.zero);
    await v.cancel();
    expect(calls, ['start', 'cancel']);
    expect(gate.isCompleted, isFalse);
    gate.complete('cancelled');
    expect(await s, VoiceStart.cancelled);
    expect(calls, ['start', 'cancel']);
    expect(v.phase, VoicePhase.idle);
  });

  test('stop while starting also calls native cancel at once', () async {
    final gate = Completer<Object?>();
    mock((c) => c.method == 'start' ? gate.future : Future.value(null));
    final v = VoiceInput();
    addTearDown(v.dispose);
    final s = v.start();
    await Future<void>.delayed(Duration.zero);
    final f = v.stop();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start', 'cancel']);
    gate.complete('unavailable');
    expect(await s, VoiceStart.cancelled);
    expect(await f, '');
  });

  test('start reply cancelled (overtaken natively) is a silent cancelled', () async {
    mock((c) async => c.method == 'start' ? 'cancelled' : null);
    final v = VoiceInput();
    addTearDown(v.dispose);
    expect(await v.start(), VoiceStart.cancelled);
    expect(v.phase, VoicePhase.idle);
  });

  test('level follows native level while listening, clamped to 0..1', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    await v.start();
    await v.handle(const MethodCall('level', {'value': .4}));
    expect(v.level.value, .4);
    await v.handle(const MethodCall('level', {'value': 1.7}));
    expect(v.level.value, 1.0);
    await v.handle(const MethodCall('level', {'value': -1}));
    expect(v.level.value, 0.0);
  });

  test('level is 0 and ignored when not listening', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    await v.handle(const MethodCall('level', {'value': .5}));
    expect(v.level.value, 0);
    await v.start();
    await v.handle(const MethodCall('level', {'value': .5}));
    expect(v.level.value, .5);
    await v.cancel();
    expect(v.level.value, 0);
  });

  test('a final while listening makes stop return it at once', () {
    fakeAsync((fa) {
      mock(ok);
      final v = VoiceInput();
      v.start();
      fa.flushMicrotasks();
      v.handle(const MethodCall('final', {'text': '好'}));
      String? got;
      v.stop().then((t) => got = t);
      fa.flushMicrotasks();
      expect(got, '好');
      expect(v.phase, VoicePhase.idle);
      v.dispose();
    });
  });

  test('start maps replies', () async {
    for (final e in {
      'asked': VoiceStart.asked,
      'denied': VoiceStart.denied,
      'preparing': VoiceStart.preparing,
      'weird': VoiceStart.unavailable,
    }.entries) {
      mock((c) async => e.key);
      final v = VoiceInput();
      expect(await v.start(), e.value, reason: e.key);
      expect(v.phase, VoicePhase.idle);
      v.dispose();
    }
    mock((c) async => throw PlatformException(code: 'x'));
    final v = VoiceInput();
    expect(await v.start(), VoiceStart.unavailable);
    expect(v.phase, VoicePhase.idle);
    v.dispose();
  });
  test('timing arrives before final and is kept', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    await v.start();
    expect(v.lastTiming, isNull);
    final f = v.stop();
    await Future<void>.delayed(Duration.zero);
    await v.handle(const MethodCall('timing', {'first_partial_ms': 420, 'final_ms': 310}));
    await v.handle(const MethodCall('final', {'text': '你好'}));
    expect(await f, '你好');
    expect(v.lastTiming?.firstPartialMs, 420);
    expect(v.lastTiming?.finalMs, 310);
  });

  test('timing may carry nulls, and is dropped while idle', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    await v.handle(const MethodCall('timing', {'first_partial_ms': 1, 'final_ms': 2}));
    expect(v.lastTiming, isNull);
    await v.start();
    await v.handle(const MethodCall('timing', {'first_partial_ms': null, 'final_ms': 90}));
    expect(v.lastTiming?.firstPartialMs, isNull);
    expect(v.lastTiming?.finalMs, 90);
  });

  test('a new start clears lastTiming', () async {
    mock(ok);
    final v = VoiceInput();
    addTearDown(v.dispose);
    await v.start();
    await v.handle(const MethodCall('timing', {'first_partial_ms': 420, 'final_ms': 310}));
    await v.handle(const MethodCall('final', {'text': '你好'}));
    expect(await v.stop(), '你好');
    expect(v.lastTiming, isNotNull);
    await v.start();
    expect(v.lastTiming, isNull);
  });
}
