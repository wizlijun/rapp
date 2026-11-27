import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/state/state_link.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late StateLink link;
  Future<void> Function(HttpRequest) handler = (_) async {};

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((r) => handler(r));
    link = StateLink(base, idle: const Duration(milliseconds: 300));
  });
  tearDown(() async {
    link.close();
    await server.close(force: true);
  });

  Future<void> json(HttpRequest r, Object body, [int status = 200]) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(body));
    await r.response.close();
  }

  test('health is true only for rapp-state', () async {
    handler = (r) => json(r, {'name': 'rapp-state', 'v': 1});
    expect(await link.health(), isTrue);
    handler = (r) => json(r, {'name': 'x'});
    expect(await link.health(), isFalse);
    handler = (r) => json(r, {'name': 'rapp-state'}, 500);
    expect(await link.health(), isFalse);
    final port = server.port;
    await server.close(force: true);
    expect(await StateLink(Uri.parse('http://127.0.0.1:$port')).health(), isFalse);
  });

  group('prefs', () {
    Map<String, Object?> health({bool routes = true}) => {'name': 'rapp-state', 'v': 2, if (routes) 'routes': true};
    final withPrefs = {
      'routes': [
        {'name': 'state', 'kind': 'builtin', 'v': 1},
        {'name': 'prefs', 'kind': 'builtin', 'v': 1},
      ],
    };

    test('prefs is true only when health has routes and /v1/routes lists prefs v1', () async {
      handler = (r) => json(r, r.uri.path == '/v1/routes' ? withPrefs : health());
      expect(await link.health(), isTrue);
      expect(link.prefs, isTrue);
      // no prefs entry
      handler = (r) => json(r, r.uri.path == '/v1/routes' ? {'routes': [{'name': 'state', 'v': 1}]} : health());
      expect(await link.health(), isTrue);
      expect(link.prefs, isFalse);
      // prefs with another version
      handler = (r) => json(r, r.uri.path == '/v1/routes' ? {'routes': [{'name': 'prefs', 'v': 2}]} : health());
      expect(await link.health(), isTrue);
      expect(link.prefs, isFalse);
      // routes 404
      handler = (r) => json(r, r.uri.path == '/v1/routes' ? {'error': 'x'} : health(), r.uri.path == '/v1/routes' ? 404 : 200);
      expect(await link.health(), isTrue);
      expect(link.prefs, isFalse);
      // health without routes: no /v1/routes call, and a stale true is cleared
      handler = (r) => json(r, r.uri.path == '/v1/routes' ? withPrefs : health());
      await link.health();
      expect(link.prefs, isTrue);
      final seen = <String>[];
      handler = (r) {
        seen.add(r.uri.path);
        return json(r, r.uri.path == '/v1/routes' ? withPrefs : health(routes: false));
      };
      expect(await link.health(), isTrue);
      expect(link.prefs, isFalse);
      expect(seen, ['/v1/health']);
      // garbage routes body
      handler = (r) async {
        if (r.uri.path == '/v1/routes') {
          r.response.write('nope');
          await r.response.close();
        } else {
          await json(r, health());
        }
      };
      expect(await link.health(), isTrue);
      expect(link.prefs, isFalse);
    });

    test('prefsAll parses the store, paths keep a manual base path', () async {
      final seen = <String>[];
      handler = (r) {
        seen.add(r.uri.path);
        return json(r, {'store': 'abcd', 'stars': {'at': 3, 'data': ['a']}});
      };
      final l = StateLink(base.replace(path: '/state'));
      final all = await l.prefsAll();
      l.close();
      expect(all['store'], 'abcd');
      expect(seen, ['/state/prefs/v1/all']);
    });

    test('putPref: 204 null, 409 doc, 500 error, body shape', () async {
      String? method;
      String? path;
      Object? sent;
      var status = 204;
      handler = (r) async {
        method = r.method;
        path = r.uri.path;
        sent = jsonDecode(await utf8.decoder.bind(r).join());
        if (status == 409) return json(r, {'at': 9, 'data': {'k': 1}}, 409);
        if (status == 500) return json(r, {'error': 'x'}, 500);
        r.response.statusCode = 204;
        await r.response.close();
      };
      expect(await link.putPref('stars', at: 5, base: 2, data: ['a']), isNull);
      expect(method, 'PUT');
      expect(path, '/prefs/v1/stars');
      expect(sent, {'at': 5, 'base': 2, 'data': ['a']});
      status = 409;
      final d = await link.putPref('stars', at: 5, base: 2, data: ['a']);
      expect(d!.at, 9);
      expect(d.data, {'k': 1});
      status = 500;
      await expectLater(
        link.putPref('stars', at: 5, base: 2, data: 1),
        throwsA(isA<StateLinkError>().having((e) => e.status, 'status', 500)),
      );
    });

    test('putUsage encodes the device id', () async {
      String? raw;
      Object? sent;
      handler = (r) async {
        raw = r.requestedUri.path;
        sent = jsonDecode(await utf8.decoder.bind(r).join());
        r.response.statusCode = 204;
        await r.response.close();
      };
      await link.putUsage('my mac/1', at: 7, data: {'a': 1});
      expect(raw, '/prefs/v1/usage/my%20mac%2F1');
      expect(sent, {'at': 7, 'data': {'a': 1}});
    });
  });

  test('state and queue pass before and limit', () async {
    final seen = <String>[];
    handler = (r) {
      seen.add(r.uri.toString());
      return json(r, r.uri.path == '/v1/queue' ? {'events': [], 'more': false} : {'sessions': []});
    };
    expect(await link.state(), {'sessions': []});
    expect(await link.queue(before: 'a:b:1'), {'events': [], 'more': false});
    await link.queue(limit: 7);
    expect(seen, ['/v1/state', '/v1/queue?before=a%3Ab%3A1&limit=50', '/v1/queue?limit=7']);
  });

  test('a base with a path keeps it in front of the API path', () async {
    final seen = <String>[];
    handler = (r) {
      seen.add(r.uri.toString());
      return json(r, r.uri.path.endsWith('/v1/health') ? {'name': 'rapp-state'} : {'events': [], 'more': false});
    };
    for (final b in ['state', 'state/']) {
      final l = StateLink(base.replace(path: '/$b'));
      expect(await l.health(), isTrue);
      await l.queue(limit: 7);
      l.close();
    }
    expect(seen, ['/state/v1/health', '/state/v1/queue?limit=7', '/state/v1/health', '/state/v1/queue?limit=7']);
  });

  test('state throws StateLinkError on a bad status or bad json', () async {
    handler = (r) => json(r, {'error': 'x'}, 500);
    await expectLater(link.state(), throwsA(isA<StateLinkError>().having((e) => e.status, 'status', 500)));
    handler = (r) async {
      r.response.write('not json');
      await r.response.close();
    };
    await expectLater(link.state(), throwsA(isA<StateLinkError>().having((e) => e.status, 'status', 0)));
  });

  test('seen sends the body and throws on 404', () async {
    String? method;
    String? body;
    handler = (r) async {
      method = r.method;
      body = await utf8.decoder.bind(r).join();
      r.response.statusCode = 204;
      await r.response.close();
    };
    await link.seen(fp: 'f', session: 's');
    expect(method, 'PUT');
    expect(jsonDecode(body!), {'fp': 'f', 'session': 's'});
    await link.seen(eid: 'a:b:1', handled: true);
    expect(jsonDecode(body!), {'eid': 'a:b:1', 'handled': true});
    handler = (r) => json(r, {'error': 'unknown eid'}, 404);
    await expectLater(link.seen(eid: 'z'), throwsA(isA<StateLinkError>().having((e) => e.status, 'status', 404)));
  });

  test('watch yields data lines and skips pings', () async {
    handler = (r) async {
      r.response
        ..bufferOutput = false
        ..headers.contentType = ContentType('text', 'event-stream');
      r.response.write(': ping\n\n'
          'data: {"what":"hello"}\n\n'
          'data: {"what":"queue","row":{"eid":"a:b:1"}}\n\n');
      await r.response.close();
    };
    expect(await link.watch().toList(), [
      {'what': 'hello'},
      {'what': 'queue', 'row': {'eid': 'a:b:1'}},
    ]);
  });

  test('a silent watch ends with an error after idle', () async {
    final hold = Completer<void>();
    handler = (r) async {
      r.response
        ..bufferOutput = false
        ..headers.contentType = ContentType('text', 'event-stream');
      await r.response.flush();
      r.response.write('data: {"what":"hello"}\n\n');
      await r.response.flush();
      await hold.future;
    };
    final got = <Object>[];
    final done = Completer<Object?>();
    link.watch().listen(got.add, onError: (Object e) {
      if (!done.isCompleted) done.complete(e);
    }, onDone: () {
      if (!done.isCompleted) done.complete(null);
    });
    final err = await done.future.timeout(const Duration(seconds: 3));
    hold.complete();
    expect(got, [
      {'what': 'hello'}
    ]);
    expect(err, isA<StateLinkError>().having((e) => e.status, 'status', 0));
  });

  test('pings keep a watch alive past idle', () async {
    final hold = Completer<void>();
    handler = (r) async {
      r.response
        ..bufferOutput = false
        ..headers.contentType = ContentType('text', 'event-stream');
      for (var i = 0; i < 4; i++) {
        r.response.write(': ping\n\n');
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      r.response.write('data: {"what":"seen"}\n\n');
      await r.response.close();
      hold.complete();
    };
    expect(await link.watch().toList(), [
      {'what': 'seen'}
    ]);
  });

  test('a non-200 watch is a stream error', () async {
    handler = (r) => json(r, {'error': 'x'}, 503);
    await expectLater(link.watch(), emitsError(isA<StateLinkError>().having((e) => e.status, 'status', 503)));
  });

  test('cancelling the watch aborts the request', () async {
    final closed = Completer<void>();
    handler = (r) async {
      // Take the raw socket: its read side ends when the client drops the connection.
      final sock = await r.response.detachSocket(writeHeaders: false);
      sock.add(utf8.encode('HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\ndata: {"what":"hello"}\n\n'));
      sock.listen((_) {}, onDone: closed.complete, onError: (_) => closed.complete());
    };
    final first = Completer<void>();
    final sub = link.watch().listen((_) => first.complete());
    await first.future;
    await sub.cancel();
    await closed.future.timeout(const Duration(seconds: 3));
  });

  test('close fails an in-flight call and is idempotent', () async {
    handler = (r) async {};
    final f = link.state();
    final check = expectLater(f, throwsA(isA<StateLinkError>().having((e) => e.status, 'status', 0)));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    link.close();
    link.close();
    await check;
  });

  test('postEvents sends ndjson', () async {
    String? method, path, ctype, body;
    handler = (r) async {
      method = r.method;
      path = r.uri.path;
      ctype = r.headers.contentType?.mimeType;
      body = await utf8.decoder.bind(r).join();
      r.response.statusCode = 204;
      await r.response.close();
    };
    await link.postEvents([
      {'a': 1},
      {'b': 'x'}
    ]);
    expect(method, 'POST');
    expect(path, '/v1/events');
    expect(ctype, 'application/x-ndjson');
    final lines = body!.trim().split('\n');
    expect(lines.map(jsonDecode).toList(), [
      {'a': 1},
      {'b': 'x'}
    ]);
    handler = (r) => json(r, {'error': 'x'}, 400);
    await expectLater(link.postEvents([{}]), throwsA(isA<StateLinkError>().having((e) => e.status, 'status', 400)));
  });

  test('putDesk encodes the fp and throws 404 as status 404', () async {
    String? method, raw, body;
    handler = (r) async {
      method = r.method;
      raw = r.uri.toString();
      body = await utf8.decoder.bind(r).join();
      r.response.statusCode = 204;
      await r.response.close();
    };
    await link.putDesk('a/b', {'x': 1});
    expect(method, 'PUT');
    expect(raw, '/v1/desk/a%2Fb');
    expect(jsonDecode(body!), {'x': 1});
    handler = (r) => json(r, {}, 404);
    await expectLater(link.putDesk('a', {}), throwsA(isA<StateLinkError>().having((e) => e.status, 'status', 404)));
  });
}
