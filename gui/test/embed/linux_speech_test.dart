import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/linux_speech.dart';
import 'package:rapp/embed/voice_input.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  final data = utf8.encode('verified model fixture');
  LinuxSpeechModel model({Uri? source}) => LinuxSpeechModel(
    file: File('${tmp.path}/cache/model'),
    source: source,
    client: () =>
        HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp()),
    bytes: data.length,
    digest: sha256.convert(data).toString(),
  );
  setUp(() => tmp = Directory.systemTemp.createTempSync('rapp-speech-test-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'Linux speech prefers Chinese and passes only Whisper language codes',
    () {
      expect(
        linuxSpeechLanguage(const [
          Locale('en', 'GB'),
          Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hans',
            countryCode: 'JP',
          ),
        ]),
        'zh',
      );
      expect(
        linuxSpeechLanguage(const [Locale('fr', 'FR'), Locale('en')]),
        'fr',
      );
      expect(linuxSpeechLanguage(const []), 'en');
      expect(
        linuxSpeechLanguage(const [
          Locale('en'),
        ], languageList: 'en_GB.UTF-8:zh_TW.UTF-8'),
        'zh',
      );
      expect(
        linuxSpeechLanguage(const [Locale('en')], languageList: 'en:zh-Hant'),
        'zh',
      );
      expect(
        linuxSpeechLanguage(const [
          Locale('en'),
        ], languageList: ' de_DE.UTF-8@euro :en'),
        'de',
      );
      expect(
        linuxSpeechLanguage(const [Locale('zh')], languageList: 'en_GB:fr'),
        'en',
      );
      expect(
        linuxSpeechLanguage(const [Locale('zh')], languageList: ' : '),
        'zh',
      );
      for (final id in ['C', 'C.UTF-8', 'POSIX']) {
        expect(linuxSpeechLanguage(const [], languageList: id), 'en');
      }
    },
  );

  for (final invalid in [false, true]) {
    test(
      'model download verifies size and SHA256 (invalid=$invalid)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        server.listen((r) async {
          requests++;
          r.response.add(invalid ? List.filled(data.length, 0) : data);
          await r.response.close();
        });
        final m = model(
          source: Uri.parse('http://127.0.0.1:${server.port}/model'),
        );
        try {
          expect(await m.readiness(), 'preparing');
          expect(await m.readiness(), 'preparing');
          await m.pending;
          expect(requests, 1);
          expect(await m.file.exists(), !invalid);
          expect(await m.readiness(), invalid ? 'unavailable' : 'ok');
          expect(
            await m.file.parent.list().where((f) => f is Directory).length,
            0,
          );
          if (invalid) {
            expect(await m.readiness(), 'preparing');
            await m.pending;
            expect(requests, 2);
          } else {
            expect(
              await model().readiness(),
              'ok',
            ); // a new app verifies its cache
          }
        } finally {
          m.dispose();
          await server.close(force: true);
        }
      },
    );
  }

  test('disposing during download leaves no model or partial files', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>();
    server.listen((r) async {
      r.response.add(data.sublist(0, 2));
      await r.response.flush();
      started.complete();
    });
    final m = model(source: Uri.parse('http://127.0.0.1:${server.port}'));
    expect(await m.readiness(), 'preparing');
    await started.future;
    m.dispose();
    await m.pending;
    await server.close(force: true);
    expect(await m.readiness(), 'cancelled');
    expect(await m.file.exists(), false);
    expect(await m.file.parent.list().length, 0);
  });

  Future<LinuxSpeechChannel> channel(
    String script, {
    Duration? startWait,
  }) async {
    final m = model();
    await m.file.parent.create(recursive: true);
    await m.file.writeAsBytes(data);
    final file = File('${tmp.path}/worker.py');
    await file.writeAsString(
      'import sys,json,time\nstart=json.loads(sys.stdin.readline())\n$script',
    );
    return LinuxSpeechChannel(
      isFocused: () async => true,
      model: m,
      executable: file.path,
      language: () => 'en',
      startWait: startWait ?? const Duration(seconds: 3),
      spawn: (exe, _) => Process.start('python3', ['-u', exe]),
    );
  }

  group('LinuxSpeechChannel python3 subprocess fixtures', () {
  test('each Linux recording receives the current learned hotwords', () async {
    final c = await channel('''
print(json.dumps({'event':'ready'}),flush=True)
json.loads(sys.stdin.readline())
print(json.dumps({'event':'final','text':json.dumps(start.get('hotwords',[]))}),flush=True)
''');
    var words = <String>['Dify'];
    final voice = VoiceInput(channel: c)..hotwords = () => words;
    try {
      for (final next in [<String>['Dify'], <String>['Python', '黑猫瑞'], <String>[]]) {
        words = next;
        expect(await voice.start(), VoiceStart.ok);
        expect(jsonDecode(await voice.stop()), next);
        await c.invokeMethod<void>('cancel');
      }
    } finally {
      voice.dispose();
    }
  });

  test(
    'timing precedes final, resets each run and ignores empty partials',
    () async {
      final c = await channel('''
print(json.dumps({'event':'ready'}),flush=True)
print(json.dumps({'event':'partial','text':''}),flush=True)
if start.get('hotwords'):
    time.sleep(.03)
    print(json.dumps({'event':'partial','text':'hello'}),flush=True)
json.loads(sys.stdin.readline())
time.sleep(.03)
print(json.dumps({'event':'final','text':'hello world'}),flush=True)
''');
      final voice = VoiceInput(
        channel: c,
        finalWait: const Duration(seconds: 3),
      );
      try {
        for (final partial in [true, false]) {
          voice.hotwords = () => partial ? ['hello'] : [];
          expect(await voice.start(), VoiceStart.ok);
          expect(voice.lastTiming, isNull);
          // The command is read only after the fixture has emitted its partial.
          expect(await voice.stop(), 'hello world');
          final timing = voice.lastTiming!;
          expect(
            timing.firstPartialMs,
            partial ? greaterThanOrEqualTo(30) : isNull,
          );
          expect(timing.finalMs, greaterThanOrEqualTo(30));
          await c.invokeMethod<void>('cancel');
        }
      } finally {
        voice.dispose();
      }
    },
  );

  test(
    'an automatic final has no stop timing and a late stop is harmless',
    () async {
      final c = await channel('''
print(json.dumps({'event':'ready'}),flush=True)
print(json.dumps({'event':'final','text':'automatic'}),flush=True)
''');
      final calls = <MethodCall>[];
      final done = Completer<void>();
      c.setMethodCallHandler((call) async {
        calls.add(call);
        if (call.method == 'final') done.complete();
      });
      try {
        expect(await c.invokeMethod<String>('start'), 'ok');
        await done.future.timeout(const Duration(seconds: 3));
        expect(calls.map((c) => c.method), ['timing', 'final']);
        expect(calls.first.arguments, {
          'first_partial_ms': null,
          'final_ms': null,
        });
        fakeAsync((clock) {
          c.invokeMethod<void>('stop');
          clock.flushMicrotasks();
          clock.elapse(LinuxSpeechChannel.finalResultWait);
          expect(calls.map((c) => c.method), ['timing', 'final']);
        });
      } finally {
        await c.invokeMethod<void>('cancel');
        c.setMethodCallHandler(null);
      }
    },
  );

  test('Linux bounds hotwords and drops malformed or control entries', () async {
    final c = await channel('''
print(json.dumps({'event':'ready'}),flush=True)
json.loads(sys.stdin.readline())
print(json.dumps({'event':'final','text':json.dumps(start['hotwords'])}),flush=True)
''');
    final voice = VoiceInput(channel: c)..hotwords = () => [
      '', '  Python  ', 'bad\u0000word', 'bad\nword', '词' * 100,
      ...List.filled(150, 'Hemory'),
    ];
    try {
      expect(await voice.start(), VoiceStart.ok);
      final words = jsonDecode(await voice.stop()) as List;
      expect(words, hasLength(100));
      expect(words.take(2), ['Python', '词' * 64]);
    } finally {
      voice.dispose();
    }
  });

  test(
    'real subprocess delivers partial, meter and final through VoiceInput',
    () async {
      final c = await channel('''
print(json.dumps({'event':'ready'}),flush=True)
print(json.dumps({'event':'partial','text':'hello'}),flush=True)
print(json.dumps({'event':'level','value':0.5}),flush=True)
cmd=json.loads(sys.stdin.readline())
assert cmd['cmd']=='stop'
print(json.dumps({'event':'final','text':'hello world'}),flush=True)
''');
      final voice = VoiceInput(
        channel: c,
        finalWait: const Duration(seconds: 3),
      );
      try {
        expect(await voice.start(), VoiceStart.ok);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(voice.text, 'hello');
        expect(voice.level.value, 0.5);
        expect(await voice.stop(), 'hello world');
        expect(voice.phase, VoicePhase.idle);
      } finally {
        voice.dispose();
      }
    },
  );

  test('a stalled recognizer is still stopped at the five-minute deadline', () async {
    final c = await channel(
      "print(json.dumps({'event':'ready'}),flush=True)\ntime.sleep(360)",
    );
    final events = <MethodCall>[];
    c.setMethodCallHandler((call) async { events.add(call); });
    try {
      expect(await c.invokeMethod<String>('start'), 'ok');
      fakeAsync((clock) {
        c.invokeMethod<void>('stop');
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 299));
        expect(events.where((e) => e.method == 'error'), isEmpty);
        clock.elapse(const Duration(seconds: 1));
        expect(events.where((e) => e.method == 'error'), hasLength(1));
      });
    } finally {
      await c.invokeMethod<void>('cancel');
      c.setMethodCallHandler(null);
    }
  });

  test(
    'cancel while starting kills the subprocess and ignores late events',
    () async {
      final spawned = Completer<Process>();
      final m = model();
      await m.file.parent.create(recursive: true);
      await m.file.writeAsBytes(data);
      final c = LinuxSpeechChannel(
        isFocused: () async => true,
        model: m,
        spawn: (_, _) async {
          final p = await Process.start('python3', [
            '-u',
            '-c',
            'import time; time.sleep(30)',
          ]);
          spawned.complete(p);
          return p;
        },
      );
      final got = <MethodCall>[];
      c.setMethodCallHandler((call) async {
        got.add(call);
      });
      final starting = c.invokeMethod<String>('start');
      final process = await spawned.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await c.invokeMethod<void>('cancel');
      expect(await starting, 'cancelled');
      expect(
        await process.exitCode.timeout(const Duration(seconds: 2)),
        isNonZero,
      );
      expect(got, isEmpty);
      c.setMethodCallHandler(null);
    },
  );

  test('a delayed hotkey after window blur never spawns a recorder', () async {
    var spawned = false;
    final c = LinuxSpeechChannel(
      model: model(),
      isFocused: () async => false,
      spawn: (_, _) async {
        spawned = true;
        throw StateError('must not spawn');
      },
    );
    c.setMethodCallHandler((_) async {});
    expect(await c.invokeMethod<String>('start'), 'cancelled');
    expect(spawned, false);
    expect(await c.model.file.parent.exists(), false);
    c.setMethodCallHandler(null);
  });

  test('worker death and startup timeout become unavailable', () async {
    for (final script in ['sys.exit(1)', 'time.sleep(30)']) {
      final c = await channel(
        script,
        startWait: const Duration(milliseconds: 150),
      );
      c.setMethodCallHandler((_) async {});
      expect(await c.invokeMethod<String>('start'), 'unavailable');
      await c.invokeMethod<void>('cancel');
      c.setMethodCallHandler(null);
    }
  });

  for (final blur in [false, true]) {
    test(
      'backgrounding or main window blur interrupts a listening worker ($blur)',
      () async {
        final c = await channel(
          "print(json.dumps({'event':'ready'}),flush=True)\ntime.sleep(30)",
        );
        final voice = VoiceInput(channel: c);
        final interrupted = Completer<String>();
        voice.onError = interrupted.complete;
        expect(await voice.start(), VoiceStart.ok);
        if (blur) {
          c.onWindowBlur();
        } else {
          c.didChangeAppLifecycleState(AppLifecycleState.inactive);
        }
        expect(
          await interrupted.future.timeout(const Duration(seconds: 2)),
          'interrupted',
        );
        expect(voice.phase, VoicePhase.idle);
        voice.dispose();
      },
    );
  }
  }, skip: Platform.isWindows ? 'H 段做完时打开' : null);
}
