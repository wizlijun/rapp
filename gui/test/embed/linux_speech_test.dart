import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
      'import sys,json,time\njson.loads(sys.stdin.readline())\n$script',
    );
    return LinuxSpeechChannel(
      model: m,
      executable: file.path,
      language: () => 'en',
      startWait: startWait ?? const Duration(seconds: 3),
      spawn: (exe, _) => Process.start('python3', ['-u', exe]),
    );
  }

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

  test(
    'cancel while starting kills the subprocess and ignores late events',
    () async {
      final spawned = Completer<Process>();
      final m = model();
      await m.file.parent.create(recursive: true);
      await m.file.writeAsBytes(data);
      final c = LinuxSpeechChannel(
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
}
