// The virtual network's LLM gateway (rapp-llm): where it is, its key (`local/llm.json`, 0600, never in git), a
// connection test, and the small text APIs (`POST /v1/apps/<name>`). The gateway answers a success with the text
// itself (200, text/plain, streamed or whole); anything else is a failure and the caller keeps the user's text.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'embed/tidy_diff.dart' show LearnAction, LearnItem;
import 'data_dir.dart' show writePrivate;

const llmFile = 'llm.json';

/// The hint shown in an empty 接入点 field: the gateway as it is usually shared into this network.
const llmUrlHint = 'http://localhost:28001';

/// Where the gateway is and the key it wants. Both empty: not set up.
class LlmEndpoint {
  const LlmEndpoint({this.url = '', this.key = ''});

  /// As typed by the user (trimmed); see [base] for the form requests use.
  final String url;
  final String key;

  bool get configured => base != null && key.isNotEmpty;

  /// [url] with a scheme (`http://` when none was typed) and no trailing `/`; null when empty or not a URL.
  String? get base => normalizeLlmUrl(url);

  /// Never throws: a missing or corrupt file gives an empty endpoint.
  static LlmEndpoint load(String localDir) {
    try {
      final j = jsonDecode(File('$localDir/$llmFile').readAsStringSync());
      if (j is! Map) return const LlmEndpoint();
      final u = j['url'], k = j['key'];
      return LlmEndpoint(url: u is String ? u.trim() : '', key: k is String ? k.trim() : '');
    } catch (_) {
      return const LlmEndpoint();
    }
  }

  /// Writes `local/llm.json` with mode 0600. Throws [FileSystemException].
  void save(String localDir) =>
      writePrivate('$localDir/$llmFile', utf8.encode(jsonEncode({'url': url, 'key': key})));

  @override
  bool operator ==(Object other) => other is LlmEndpoint && other.url == url && other.key == key;

  @override
  int get hashCode => Object.hash(url, key);
}

/// `localhost:28001` → `http://localhost:28001`; trailing slashes go. Null when [s] is empty or has no host.
String? normalizeLlmUrl(String s) {
  var t = s.trim();
  if (t.isEmpty) return null;
  if (!t.contains('://')) t = 'http://$t';
  while (t.endsWith('/')) {
    t = t.substring(0, t.length - 1);
  }
  final u = Uri.tryParse(t);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty) return null;
  return t;
}

/// What 测试 found.
sealed class LlmProbe {
  const LlmProbe();

  /// One line for the settings row.
  String get line;
  bool get ok => false;
}

class LlmProbeOk extends LlmProbe {
  const LlmProbeOk(this.apps, this.elapsed);

  /// The small APIs the gateway offers (`GET /v1/apps`).
  final List<String> apps;
  final Duration elapsed;

  @override
  bool get ok => true;

  @override
  String get line => '已连通 · ${elapsed.inMilliseconds} ms · ${apps.isEmpty ? '没有小 API' : apps.join('、')}';
}

class LlmProbeFailed extends LlmProbe {
  const LlmProbeFailed(this.line);

  @override
  final String line;
}

/// The result of one small-API call.
sealed class LlmResult {
  const LlmResult();
}

class LlmDone extends LlmResult {
  const LlmDone(this.text);
  final String text;
}

/// The call did not finish with a whole answer; [reason] is short and fit for the user (the gateway's own
/// message goes to the log only).
class LlmFailed extends LlmResult {
  const LlmFailed(this.reason, {this.log = ''});
  final String reason;
  final String log;
}

/// Cancelled by the caller ([LlmCall.cancel]).
class LlmCancelled extends LlmResult {
  const LlmCancelled();
}

/// One running small-API call; [result] completes once, [cancel] makes it complete with [LlmCancelled] and drops
/// the connection (the gateway then cancels upstream).
class LlmCall {
  LlmCall._(this._client);

  /// A call with no connection behind it, which the test ends with [complete].
  @visibleForTesting
  LlmCall.manual() : _client = null;

  final HttpClient? _client;
  final _done = Completer<LlmResult>();
  bool _cancelled = false;

  Future<LlmResult> get result => _done.future;
  bool get cancelled => _cancelled;

  void cancel() {
    if (_done.isCompleted) return;
    _cancelled = true;
    _client?.close(force: true);
    _done.complete(const LlmCancelled());
  }

  @visibleForTesting
  void complete(LlmResult r) => _finish(r);

  void _finish(LlmResult r) {
    if (!_done.isCompleted) _done.complete(r);
    _client?.close(force: true);
  }
}

/// Talks to the gateway. Stateless apart from the endpoint it is given per call.
class LlmApi {
  const LlmApi({this.probeTimeout = const Duration(seconds: 5)});

  final Duration probeTimeout;

  /// `GET /v1/apps` with the key: checks the address, the key and that the gateway answers.
  Future<LlmProbe> probe(LlmEndpoint e) async {
    final base = e.base;
    if (base == null) return const LlmProbeFailed('接入点不是有效的地址');
    if (e.key.isEmpty) return const LlmProbeFailed('还没有填 key');
    final client = HttpClient()..connectionTimeout = probeTimeout;
    final t0 = DateTime.now();
    try {
      final req = await client.getUrl(Uri.parse('$base/v1/apps')).timeout(probeTimeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${e.key}');
      final res = await req.close().timeout(probeTimeout);
      final body = await res.transform(utf8.decoder).join().timeout(probeTimeout);
      final elapsed = DateTime.now().difference(t0);
      if (res.statusCode == 200) {
        final j = jsonDecode(body);
        final data = j is Map ? j['data'] : null;
        final apps = [
          if (data is List)
            for (final a in data)
              if (a is Map && a['id'] is String) a['id'] as String,
        ];
        return LlmProbeOk(apps, elapsed);
      }
      final code = _errorCode(body);
      if (res.statusCode == 401) return const LlmProbeFailed('key 不对');
      if (res.statusCode == 404) return const LlmProbeFailed('这个地址上不是 rapp-llm 网关');
      return LlmProbeFailed('网关返回 ${res.statusCode}${code.isEmpty ? '' : ' $code'}');
    } on TimeoutException {
      return LlmProbeFailed('${probeTimeout.inSeconds} 秒没有回应');
    } on SocketException catch (x) {
      return LlmProbeFailed('连不上：${x.osError?.message ?? x.message}');
    } on HandshakeException {
      return const LlmProbeFailed('TLS 握手失败');
    } on FormatException {
      return const LlmProbeFailed('这个地址上不是 rapp-llm 网关');
    } catch (x) {
      return LlmProbeFailed('出错：$x');
    } finally {
      client.close(force: true);
    }
  }

  /// `GET /v1/hotwords`: the words the speech recogniser should expect (names, products). Never throws; not set
  /// up, a failure or an old gateway without it all give an empty list.
  Future<List<String>> hotwords(LlmEndpoint e) async {
    final base = e.base;
    if (base == null || e.key.isEmpty) return const [];
    final client = HttpClient()..connectionTimeout = probeTimeout;
    try {
      final req = await client.getUrl(Uri.parse('$base/v1/hotwords')).timeout(probeTimeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${e.key}');
      final res = await req.close().timeout(probeTimeout);
      final body = await res.transform(utf8.decoder).join().timeout(probeTimeout);
      if (res.statusCode != 200) return const [];
      final j = jsonDecode(body);
      final data = j is Map ? j['data'] : null;
      return [
        if (data is List)
          for (final w in data)
            if (w is String && w.isNotEmpty) w,
      ];
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  /// `POST /v1/vocabulary/learn`: teaches the gateway one correction. True only on a 200; never throws.
  Future<bool> learn(LlmEndpoint e, LearnItem item) async {
    final base = e.base;
    if (base == null || e.key.isEmpty) return false;
    final client = HttpClient()..connectionTimeout = probeTimeout;
    try {
      final req = await client.postUrl(Uri.parse('$base/v1/vocabulary/learn')).timeout(probeTimeout);
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${e.key}')
        ..contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(item.toJson())));
      final res = await req.close().timeout(probeTimeout);
      await res.drain<void>().timeout(probeTimeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// `GET /v1/vocabulary/learned`: what was taught. Null: not set up, unreachable or not a 200. Never throws.
  Future<List<LearnedEntry>?> learned(LlmEndpoint e) async {
    final base = e.base;
    if (base == null || e.key.isEmpty) return null;
    final client = HttpClient()..connectionTimeout = probeTimeout;
    try {
      final req = await client.getUrl(Uri.parse('$base/v1/vocabulary/learned')).timeout(probeTimeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${e.key}');
      final res = await req.close().timeout(probeTimeout);
      final body = await res.transform(utf8.decoder).join().timeout(probeTimeout);
      if (res.statusCode != 200) return null;
      final j = jsonDecode(body);
      final data = j is Map ? j['data'] : null;
      if (data is! List) return null;
      return [
        for (final d in data)
          if (d is Map && d['id'] is String && d['observed'] is String)
            if (_learnAction(d['action']) case final a?)
              LearnedEntry(
                id: d['id'] as String,
                action: a,
                observed: d['observed'] as String,
                output: d['output'] is String ? d['output'] as String : null,
              ),
      ];
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// `DELETE /v1/vocabulary/learned/<id>`: true only on a 200; never throws.
  Future<bool> forget(LlmEndpoint e, String id) async {
    final base = e.base;
    if (base == null || e.key.isEmpty) return false;
    final client = HttpClient()..connectionTimeout = probeTimeout;
    try {
      final req = await client
          .deleteUrl(Uri.parse('$base/v1/vocabulary/learned/${Uri.encodeComponent(id)}'))
          .timeout(probeTimeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${e.key}');
      final res = await req.close().timeout(probeTimeout);
      await res.drain<void>().timeout(probeTimeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static LearnAction? _learnAction(Object? a) => switch (a) {
        'replace' => LearnAction.replace,
        'preserve' => LearnAction.preserve,
        _ => null,
      };

  /// `POST /v1/apps/<app>` streamed. [onText] gets the whole text so far after each chunk. Completes with
  /// [LlmDone] only when the gateway finished normally; a non-200, a dropped stream or no first byte within
  /// [firstByte] is [LlmFailed]. [think]: the app's think.* settings go up too (dictation: the model thinks first).
  LlmCall run(
    LlmEndpoint e,
    String app,
    String input, {
    Map<String, String>? vars,
    void Function(String text)? onText,
    Duration firstByte = const Duration(seconds: 10),
    bool think = false,
  }) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final call = LlmCall._(client);
    unawaited(_run(call, client, e, app, input, vars, onText, firstByte, think));
    return call;
  }

  Future<void> _run(LlmCall call, HttpClient client, LlmEndpoint e, String app, String input,
      Map<String, String>? vars, void Function(String)? onText, Duration firstByte, bool think) async {
    final base = e.base;
    if (base == null || e.key.isEmpty) return call._finish(const LlmFailed('没有设置 LLM 接入点'));
    try {
      final req = await client.postUrl(Uri.parse('$base/v1/apps/$app'));
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${e.key}')
        ..contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'input': input, 'stream': true, 'vars': ?vars, if (think) 'think': true})));
      // The gateway holds the status until upstream's first byte (or its own timeout): wait a little longer.
      final res = await req.close().timeout(firstByte + const Duration(seconds: 5));
      if (res.statusCode != 200) {
        final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 5), onTimeout: () => '');
        final code = _errorCode(body);
        return call._finish(LlmFailed(_statusReason(res.statusCode, code), log: '${res.statusCode} $code'));
      }
      final buf = StringBuffer();
      await for (final chunk in res.transform(utf8.decoder)) {
        if (call.cancelled) return;
        buf.write(chunk);
        onText?.call(buf.toString());
      }
      if (call.cancelled) return;
      call._finish(LlmDone(buf.toString()));
    } on TimeoutException {
      call._finish(const LlmFailed('LLM 没有及时回应', log: 'timeout'));
    } on SocketException catch (x) {
      call._finish(LlmFailed('连不上 LLM 接入点', log: x.osError?.message ?? x.message));
    } on HttpException catch (x) {
      call._finish(LlmFailed('LLM 中途断开', log: x.message));
    } catch (x) {
      call._finish(LlmFailed('LLM 出错', log: '$x'));
    }
  }

  static String _statusReason(int status, String code) => switch ((status, code)) {
        (401, _) => 'LLM 接入点的 key 不对',
        (404, _) => 'LLM 网关没有这个功能',
        (504, _) || (_, 'upstream_timeout') => 'LLM 没有及时回应',
        (502, 'upstream_unreachable') => 'LLM 网关连不上模型',
        (429, _) => 'LLM 正忙（限流）',
        _ => 'LLM 出错（$status）',
      };

  static String _errorCode(String body) {
    try {
      final j = jsonDecode(body);
      final c = j is Map && j['error'] is Map ? (j['error'] as Map)['code'] : null;
      return c is String ? c : '';
    } catch (_) {
      return '';
    }
  }
}

/// One correction the gateway holds (`GET /v1/vocabulary/learned`).
class LearnedEntry {
  const LearnedEntry({required this.id, required this.action, required this.observed, this.output});

  final String id;
  final LearnAction action;
  final String observed;
  final String? output;

  String get label => action == LearnAction.replace ? '$observed → $output' : '不改：$observed';
}
