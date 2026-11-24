import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/tidy_diff.dart';
import 'package:rapp/embed/voice_fix.dart';
import 'package:rapp/llm_api.dart';

void main() {
  group('normalizeLlmUrl', () {
    test('adds http and drops trailing slashes', () {
      expect(normalizeLlmUrl(' localhost:28001/ '), 'http://localhost:28001');
      expect(normalizeLlmUrl('https://x.example/'), 'https://x.example');
      expect(normalizeLlmUrl('http://127.0.0.1:8101'), 'http://127.0.0.1:8101');
    });
    test('rejects empty and non-http', () {
      expect(normalizeLlmUrl(''), isNull);
      expect(normalizeLlmUrl('ftp://x'), isNull);
      expect(normalizeLlmUrl('http://'), isNull);
    });
  });

  group('LlmEndpoint file', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('llm_api_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('round-trips and is private', () {
      const e = LlmEndpoint(url: 'localhost:28001', key: 'rl-1');
      e.save(tmp.path);
      expect(LlmEndpoint.load(tmp.path), e);
      expect(LlmEndpoint.load(tmp.path).configured, isTrue);
      if (!Platform.isWindows) {
        expect(File('${tmp.path}/$llmFile').statSync().modeString(), 'rw-------');
      }
    });

    test('missing or corrupt gives empty', () {
      expect(LlmEndpoint.load(tmp.path).configured, isFalse);
      File('${tmp.path}/$llmFile').writeAsStringSync('{not json');
      expect(LlmEndpoint.load(tmp.path), const LlmEndpoint());
    });
  });


  group('VoiceRulesCopy file', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('llm_api_rules'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('round-trips and is private', () async {
      final c = VoiceRulesCopy(
        endpoint: 'http://localhost:28001',
        fetchedAt: DateTime.utc(2026, 11, 25, 9),
        etag: 'e1',
        rules: const [FixRule.replace('徐逊', '徐迅', FixSource.vocabulary), FixRule.preserve('黑猫瑞', FixSource.learned)],
      );
      await c.save(tmp.path);
      final back = (await VoiceRulesCopy.load(tmp.path))!;
      expect(back.endpoint, c.endpoint);
      expect(back.fetchedAt, c.fetchedAt);
      expect(back.etag, 'e1');
      expect(back.rules, c.rules);
      final j = jsonDecode(File('${tmp.path}/$voiceRulesFile').readAsStringSync()) as Map;
      expect(j.keys, containsAll(['endpoint', 'fetchedAt', 'etag', 'rules']));
      if (!Platform.isWindows) {
        expect(File('${tmp.path}/$voiceRulesFile').statSync().modeString(), 'rw-------');
      }
    });

    test('missing or corrupt is null; a bad rule is skipped', () async {
      expect(await VoiceRulesCopy.load(tmp.path), isNull);
      File('${tmp.path}/$voiceRulesFile').writeAsStringSync('{not json');
      expect(await VoiceRulesCopy.load(tmp.path), isNull);
      File('${tmp.path}/$voiceRulesFile').writeAsStringSync(jsonEncode({'endpoint': 'x', 'rules': []}));
      expect(await VoiceRulesCopy.load(tmp.path), isNull);
      File('${tmp.path}/$voiceRulesFile').writeAsStringSync(jsonEncode({
        'endpoint': 'http://localhost:28001',
        'fetchedAt': '2026-11-25T09:00:00.000Z',
        'etag': 'e1',
        'rules': [
          {'action': 'replace', 'observed': '徐逊', 'output': '徐迅', 'source': 'vocabulary'},
          {'action': 'weird', 'observed': 'x', 'source': 'learned'},
          7,
        ],
      }));
      expect((await VoiceRulesCopy.load(tmp.path))!.rules, const [FixRule.replace('徐逊', '徐迅', FixSource.vocabulary)]);
    });
  });

  group('against a fake gateway', () {
    late HttpServer server;
    late Future<void> Function(HttpRequest) handler;
    late LlmEndpoint ep;
    const key = 'rl-test';

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) => handler(r));
      ep = LlmEndpoint(url: 'localhost:${server.port}', key: key);
    });
    tearDown(() => server.close(force: true));

    bool authed(HttpRequest r) => r.headers.value(HttpHeaders.authorizationHeader) == 'Bearer $key';

    test('hotwords reads the list with the key; anything wrong is an empty list', () async {
      handler = (r) async {
        expect(r.method, 'GET');
        expect(r.uri.path, '/v1/hotwords');
        if (!authed(r)) {
          r.response.statusCode = 401;
        } else {
          r.response.write(jsonEncode({
            'object': 'list',
            'data': ['Dify', 3, 'Lovable', '']
          }));
        }
        await r.response.close();
      };
      expect(await const LlmApi().hotwords(ep), ['Dify', 'Lovable']);
      expect(await const LlmApi().hotwords(LlmEndpoint(url: ep.url, key: 'wrong')), isEmpty);
      expect(await const LlmApi().hotwords(const LlmEndpoint()), isEmpty);
      handler = (r) async {
        r.response.statusCode = 404;
        await r.response.close();
      };
      expect(await const LlmApi().hotwords(ep), isEmpty);
    });


    test('rules: 200 with the key, bad entries skipped, the etag kept', () async {
      String? inm;
      handler = (r) async {
        expect(r.method, 'GET');
        expect(r.uri.path, '/v1/vocabulary/rules');
        expect(authed(r), isTrue);
        inm = r.headers.value(HttpHeaders.ifNoneMatchHeader);
        r.response.headers.set(HttpHeaders.etagHeader, '"e1"');
        r.response.write(jsonEncode({
          'etag': 'e1',
          'rules': [
            {'action': 'replace', 'observed': '徐逊', 'output': '徐迅', 'source': 'vocabulary'},
            {'action': 'replace', 'observed': 'x'},
            {'action': 'preserve', 'observed': '黑猫瑞', 'source': 'learned'},
            'junk',
          ],
        }));
        await r.response.close();
      };
      final r = (await const LlmApi().rules(ep))!;
      expect(inm, isNull);
      expect(r.unchanged, isFalse);
      expect(r.etag, 'e1');
      expect(r.rules, const [
        FixRule.replace('徐逊', '徐迅', FixSource.vocabulary),
        FixRule.preserve('黑猫瑞', FixSource.learned),
      ]);
    });

    test('rules: the etag goes up quoted; 304 is unchanged', () async {
      String? inm;
      handler = (r) async {
        inm = r.headers.value(HttpHeaders.ifNoneMatchHeader);
        r.response.statusCode = 304;
        await r.response.close();
      };
      final r = (await const LlmApi().rules(ep, etag: 'e1'))!;
      expect(inm, '"e1"');
      expect(r.unchanged, isTrue);
      expect(r.etag, 'e1');
      expect(r.rules, isEmpty);
    });

    test('rules: the etag header serves when the body has none', () async {
      handler = (r) async {
        r.response.headers.set(HttpHeaders.etagHeader, '"e2"');
        r.response.write(jsonEncode({'rules': []}));
        await r.response.close();
      };
      expect((await const LlmApi().rules(ep))!.etag, 'e2');
    });

    test('rules: 404, bad JSON, not set up and no server are null', () async {
      handler = (r) async {
        r.response.statusCode = 404;
        await r.response.close();
      };
      expect(await const LlmApi().rules(ep), isNull);
      handler = (r) async {
        r.response.write('{nope');
        await r.response.close();
      };
      expect(await const LlmApi().rules(ep), isNull);
      handler = (r) async {
        r.response.write(jsonEncode({'etag': 'e1', 'rules': 'nope'}));
        await r.response.close();
      };
      expect(await const LlmApi().rules(ep), isNull);
      expect(await const LlmApi().rules(const LlmEndpoint()), isNull);
      await server.close(force: true);
      expect(await const LlmApi().rules(ep), isNull);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0); // for tearDown
    });

    const item = LearnItem.replace(observed: '黑猫瑞', output: 'Hemory', excerpt: '我们用黑猫瑞');

    test('learn posts the item as JSON with the key', () async {
      Map<String, Object?>? got;
      String? auth, method, path;
      handler = (r) async {
        method = r.method;
        path = r.uri.path;
        auth = r.headers.value(HttpHeaders.authorizationHeader);
        got = (jsonDecode(await utf8.decoder.bind(r).join()) as Map).cast<String, Object?>();
        r.response.write(jsonEncode({'id': 'l1', 'object': 'learned'}));
        await r.response.close();
      };
      expect(await const LlmApi().learn(ep, item), isTrue);
      expect(method, 'POST');
      expect(path, '/v1/vocabulary/learn');
      expect(auth, 'Bearer k'.replaceFirst('k', key));
      expect(got, item.toJson());
    });

    test('learn is false on 500 and on no server', () async {
      handler = (r) async {
        r.response.statusCode = 500;
        await r.response.close();
      };
      expect(await const LlmApi().learn(ep, item), isFalse);
      expect(await const LlmApi().learn(const LlmEndpoint(), item), isFalse);
      await server.close(force: true);
      expect(await const LlmApi().learn(ep, item), isFalse);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0); // for tearDown
    });

    test('learned parses the list', () async {
      handler = (r) async {
        expect(r.method, 'GET');
        expect(r.uri.path, '/v1/vocabulary/learned');
        expect(authed(r), isTrue);
        r.response.write(jsonEncode({
          'object': 'list',
          'data': [
            {'id': 'a', 'object': 'learned', 'action': 'replace', 'observed': '黑猫瑞', 'output': 'Hemory'},
            {'id': 'b', 'object': 'learned', 'action': 'preserve', 'observed': '嗯', 'output': null},
            {'id': 'c', 'action': 'weird', 'observed': 'x'},
            7,
          ]
        }));
        await r.response.close();
      };
      final l = (await const LlmApi().learned(ep))!;
      expect([for (final e in l) e.id], ['a', 'b']);
      expect(l[0].action, LearnAction.replace);
      expect(l[0].label, '黑猫瑞 → Hemory');
      expect(l[1].action, LearnAction.preserve);
      expect(l[1].label, '不改：嗯');
    });

    test('learned is null on 404', () async {
      handler = (r) async {
        r.response.statusCode = 404;
        await r.response.close();
      };
      expect(await const LlmApi().learned(ep), isNull);
      expect(await const LlmApi().learned(const LlmEndpoint()), isNull);
    });

    test('forget sends DELETE to the id', () async {
      String? method, path;
      var status = 200;
      handler = (r) async {
        method = r.method;
        path = r.uri.path;
        r.response.statusCode = status;
        await r.response.close();
      };
      expect(await const LlmApi().forget(ep, 'abc'), isTrue);
      expect(method, 'DELETE');
      expect(path, '/v1/vocabulary/learned/abc');
      status = 404;
      expect(await const LlmApi().forget(ep, 'abc'), isFalse);
    });

    Future<void> error(HttpRequest r, int status, String code) async {
      r.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': {'message': '中文', 'type': 't', 'code': code}
        }));
      await r.response.close();
    }

    test('probe ok lists the apps', () async {
      handler = (r) async {
        if (!authed(r)) return error(r, 401, 'invalid_api_key');
        r.response.write(jsonEncode({
          'object': 'list',
          'data': [
            {'id': 'correct'},
            {'id': 'dictation'},
          ]
        }));
        await r.response.close();
      };
      final p = await const LlmApi().probe(ep);
      expect(p, isA<LlmProbeOk>());
      expect((p as LlmProbeOk).apps, ['correct', 'dictation']);
      expect(p.line, startsWith('已连通'));
    });

    test('probe with a wrong key', () async {
      handler = (r) => error(r, 401, 'invalid_api_key');
      final p = await const LlmApi().probe(LlmEndpoint(url: ep.url, key: 'nope'));
      expect(p.ok, isFalse);
      expect(p.line, 'key 不对');
    });

    test('probe with nothing listening', () async {
      final port = server.port;
      await server.close(force: true);
      final p = await const LlmApi().probe(LlmEndpoint(url: 'localhost:$port', key: key));
      expect(p.ok, isFalse);
      expect(p.line, startsWith('连不上'));
    });

    test('probe before the fields are filled', () async {
      expect((await const LlmApi().probe(const LlmEndpoint(key: key))).line, '接入点不是有效的地址');
      expect((await const LlmApi().probe(LlmEndpoint(url: ep.url))).line, '还没有填 key');
    });

    test('run streams and finishes', () async {
      handler = (r) async {
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        expect(body['stream'], isTrue);
        expect(r.uri.path, '/v1/apps/dictation');
        r.response.headers.contentType = ContentType.text;
        r.response.write('我们明天');
        await r.response.flush();
        r.response.write('开会。');
        await r.response.close();
      };
      final seen = <String>[];
      final call = const LlmApi().run(ep, 'dictation', '我门明天开会', onText: seen.add);
      final res = await call.result;
      expect(res, isA<LlmDone>());
      expect((res as LlmDone).text, '我们明天开会。');
      expect(seen.last, '我们明天开会。');
    });

    test('run asks the gateway to think only when told', () async {
      final seen = <Object?>[];
      handler = (r) async {
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        seen.add(body.containsKey('think') ? body['think'] : 'absent');
        r.response.headers.contentType = ContentType.text;
        r.response.write('好');
        await r.response.close();
      };
      await const LlmApi().run(ep, 'dictation', 'x').result;
      await const LlmApi().run(ep, 'dictation', 'x', think: true).result;
      expect(seen, ['absent', true]);
    });

    test('run fails on a non-200', () async {
      handler = (r) => error(r, 502, 'upstream_unreachable');
      final res = await const LlmApi().run(ep, 'dictation', 'x').result;
      expect(res, isA<LlmFailed>());
      expect((res as LlmFailed).reason, 'LLM 网关连不上模型');
    });

    test('run fails when the stream is cut', () async {
      handler = (r) async {
        await utf8.decoder.bind(r).join();
        final s = await r.response.detachSocket(writeHeaders: false);
        // Chunked, one chunk, then the connection drops without the last (zero) chunk.
        s.add(utf8.encode('HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\n'
            'transfer-encoding: chunked\r\n\r\n6\r\n半句\r\n'));
        await s.flush();
        s.destroy();
      };
      final res = await const LlmApi().run(ep, 'dictation', 'x').result;
      expect(res, isA<LlmFailed>());
    });

    test('cancel completes at once with LlmCancelled', () async {
      final hold = Completer<void>();
      handler = (r) async {
        await hold.future;
        await r.response.close();
      };
      final call = const LlmApi().run(ep, 'dictation', 'x');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      call.cancel();
      expect(await call.result, isA<LlmCancelled>());
      hold.complete();
    });
  });
}
