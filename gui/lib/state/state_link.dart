// HTTP + SSE client for the center service (rapp-center) (`services/center/api/http.md`). Plain dart:io, no dependencies.
// Event text is never logged; it can carry what the user typed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../quick/quick_prefs.dart';

/// A failed call. [status] is the HTTP status; 0 for a network error, a timeout, bad JSON or a closed link.
class StateLinkError implements Exception {
  const StateLinkError(this.status);
  final int status;

  @override
  String toString() => 'StateLinkError($status)';
}

class StateLink {
  StateLink(this.base, {this.connect = const Duration(seconds: 5), this.idle = const Duration(seconds: 45)});

  final Uri base;

  /// Connect timeout. A plain request (health, state, queue, seen) may take [connect] + [idle] in all (50 s by
  /// default) before it fails with `StateLinkError(0)`.
  final Duration connect;

  /// A watch that hears nothing (not even a ping) for this long ends with `StateLinkError(0)`.
  final Duration idle;

  final _open = <HttpClient>{};
  bool _closed = false;

  HttpClient _client() {
    if (_closed) throw const StateLinkError(0);
    final c = HttpClient()..connectionTimeout = connect;
    _open.add(c);
    return c;
  }

  void _release(HttpClient c) {
    _open.remove(c);
    c.close(force: true);
  }

  /// [path] under [base]'s own path, so a manual `https://host/state` reaches `https://host/state/v1/…`.
  Uri _uri(String path, [Map<String, String>? query]) {
    var prefix = base.path;
    while (prefix.endsWith('/')) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return base.replace(path: '$prefix$path', queryParameters: query == null || query.isEmpty ? null : query);
  }

  /// True when the last [health] found a service that lists the `prefs` builtin (v1) in `/v1/routes`.
  bool prefs = false;

  /// True only for a 200 from a center service. Never throws. Also refreshes [prefs].
  Future<bool> health() async {
    prefs = false;
    try {
      final j = await _getJson(_uri('/v1/health'));
      if (j['name'] != 'rapp-state') return false;
      if (j['routes'] == true) {
        try {
          final r = await _getJson(_uri('/v1/routes'));
          final list = r['routes'];
          prefs = list is List && list.any((e) => e is Map && e['name'] == 'prefs' && e['v'] == 1);
        } catch (_) {
          prefs = false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// `GET /prefs/v1/all`: the store id, the four documents and the per-device usage.
  Future<Map<String, Object?>> prefsAll() => _getJson(_uri('/prefs/v1/all'));

  /// Puts document [name] (`base` = the `at` we believe the service has). 204 returns null; 409 returns the stored
  /// document; anything else throws `StateLinkError(status)`.
  Future<QuickDoc?> putPref(String name, {required int at, required int base, required Object? data}) async {
    final (status, text) = await _sendRaw(
      'PUT',
      _uri('/prefs/v1/${Uri.encodeComponent(name)}'),
      jsonEncode({'at': at, 'base': base, 'data': data}),
      'application/json',
    );
    if (status == 204) return null;
    if (status == 409) {
      try {
        final j = jsonDecode(text);
        if (j is Map && j['at'] is int) return QuickDoc(j['at'] as int, j['data']);
      } catch (_) {}
      throw const StateLinkError(0);
    }
    throw StateLinkError(status);
  }

  /// Replaces this [device]'s usage whole.
  Future<void> putUsage(String device, {required int at, required Object? data}) => _send(
    'PUT',
    _uri('/prefs/v1/usage/${Uri.encodeComponent(device)}'),
    jsonEncode({'at': at, 'data': data}),
    'application/json',
  );

  Future<Map<String, Object?>> state() => _getJson(_uri('/v1/state'));

  Future<Map<String, Object?>> queue({String? before, int limit = 50}) =>
      _getJson(_uri('/v1/queue', {'before': ?before, 'limit': '$limit'}));

  /// Marks a session row (`fp` + `session`) or a queue row (`eid`) as seen. Throws [StateLinkError] unless 2xx.
  Future<void> seen({String? fp, String? session, String? eid, bool handled = false}) async {
    final body = jsonEncode({
      ...eid != null ? {'eid': eid} : {'fp': fp, 'session': session},
      if (handled) 'handled': true,
    });
    final c = _client();
    try {
      final res = await _run(() async {
        final req = await c.putUrl(_uri('/v1/seen'));
        req.headers.contentType = ContentType.json;
        req.write(body);
        final res = await req.close();
        await res.drain<void>();
        return res;
      });
      if (res.statusCode < 200 || res.statusCode > 299) throw StateLinkError(res.statusCode);
    } finally {
      _release(c);
    }
  }

  /// The change feed. Single subscription; the request starts on listen and a cancel aborts it. The first event is
  /// `{"what":"hello"}`. A non-200 reply is an error `StateLinkError(status)`; [idle] of silence is `StateLinkError(0)`;
  /// the service closing the connection ends the stream normally.
  Stream<Map<String, Object?>> watch() {
    late final StreamController<Map<String, Object?>> out;
    HttpClient? client;
    StreamSubscription<String>? sub;
    Timer? timer;
    var finished = false;

    void finish([Object? error]) {
      if (finished) return;
      finished = true;
      timer?.cancel();
      sub?.cancel();
      if (client != null) _release(client!);
      if (error != null) out.addError(error);
      out.close();
    }

    void arm() {
      timer?.cancel();
      timer = Timer(idle, () => finish(const StateLinkError(0)));
    }

    Future<void> start() async {
      try {
        client = _client();
        arm();
        final req = await client!.getUrl(_uri('/v1/watch'));
        req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        final res = await req.close();
        if (finished) return;
        if (res.statusCode != 200) {
          await res.drain<void>().catchError((_) {});
          return finish(StateLinkError(res.statusCode));
        }
        arm();
        final data = StringBuffer();
        sub = res.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          arm();
          if (line.isEmpty) {
            if (data.isEmpty) return;
            final text = data.toString();
            data.clear();
            try {
              final j = jsonDecode(text);
              if (j is! Map<String, Object?>) return finish(const StateLinkError(0));
              out.add(j);
            } catch (_) {
              finish(const StateLinkError(0));
            }
          } else if (line.startsWith('data:')) {
            if (data.isNotEmpty) data.write('\n');
            data.write(line.substring(5).trimLeft());
          }
        }, onError: (_) => finish(const StateLinkError(0)), onDone: finish, cancelOnError: true);
      } on StateLinkError catch (e) {
        finish(e);
      } catch (_) {
        finish(const StateLinkError(0));
      }
    }

    out = StreamController<Map<String, Object?>>(
      onListen: start,
      onCancel: () {
        finished = true;
        timer?.cancel();
        sub?.cancel();
        if (client != null) _release(client!);
      },
    );
    return out.stream;
  }

  /// Posts [events] (one JSON object per line). Any 2xx is success; another status throws `StateLinkError(status)`.
  Future<void> postEvents(List<Map<String, Object?>> events) =>
      _send('POST', _uri('/v1/events'), '${events.map(jsonEncode).join('\n')}\n', 'application/x-ndjson');

  /// Puts this app's desk [body] under fingerprint [fp]. A service without the desk route answers 404.
  Future<void> putDesk(String fp, Map<String, Object?> body) =>
      _send('PUT', _uri('/v1/desk/${Uri.encodeComponent(fp)}'), jsonEncode(body), 'application/json');

  Future<void> _send(String method, Uri url, String body, String contentType) async {
    final (status, _) = await _sendRaw(method, url, body, contentType);
    if (status < 200 || status >= 300) throw StateLinkError(status);
  }

  /// Sends a request and returns the status and the reply body, whatever the status.
  Future<(int, String)> _sendRaw(String method, Uri url, String body, String contentType) async {
    final c = _client();
    try {
      return await _run(() async {
        final req = await c.openUrl(method, url);
        req.headers.contentType = ContentType.parse(contentType);
        req.write(body);
        final res = await req.close();
        final text = await utf8.decoder.bind(res).join();
        return (res.statusCode, text);
      });
    } finally {
      _release(c);
    }
  }

  /// Aborts every request in flight (they fail with `StateLinkError(0)`, a watch ends). Safe to call twice.
  void close() {
    _closed = true;
    for (final c in _open.toList()) {
      c.close(force: true);
    }
    _open.clear();
  }

  Future<Map<String, Object?>> _getJson(Uri url) async {
    final c = _client();
    try {
      return await _run(() async {
        final req = await c.getUrl(url);
        final res = await req.close();
        final text = await utf8.decoder.bind(res).join();
        if (res.statusCode != 200) throw StateLinkError(res.statusCode);
        final j = jsonDecode(text);
        if (j is! Map<String, Object?>) throw const StateLinkError(0);
        return j;
      });
    } finally {
      _release(c);
    }
  }

  /// Runs [f] with the plain-request timeout; any failure that is not already a [StateLinkError] becomes status 0.
  Future<T> _run<T>(Future<T> Function() f) async {
    try {
      return await f().timeout(connect + idle);
    } on StateLinkError {
      rethrow;
    } catch (_) {
      throw const StateLinkError(0);
    }
  }
}
