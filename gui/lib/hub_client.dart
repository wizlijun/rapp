// Talks to the rapp-hub child process over stdin/stdout JSON lines (spec §4).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One JSON object per line, `\n`-terminated.
String encodeLine(Map<String, dynamic> m) => '${jsonEncode(m)}\n';

/// Parses a line into a JSON object; anything else (logs, garbage) → null.
Map<String, dynamic>? decodeLine(String line) {
  final s = line.trim();
  if (s.isEmpty) return null;
  try {
    final v = jsonDecode(s);
    return v is Map<String, dynamic> ? v : null;
  } on FormatException {
    return null;
  }
}

/// Line-oriented pipe to the hub; a fake replaces it in tests.
abstract class HubTransport {
  Stream<String> get lines;
  void send(String line);
  Future<void> close();
}

/// The real hub: a child process, stdout lines in, stdin lines out.
class ProcessHubTransport implements HubTransport {
  ProcessHubTransport._(this._p)
      : lines = _p.stdout.transform(utf8.decoder).transform(const LineSplitter()) {
    _p.stderr.listen(stderr.add);
  }

  final Process _p;
  @override
  final Stream<String> lines;

  static Future<ProcessHubTransport> start(String exe) async =>
      ProcessHubTransport._(await Process.start(exe, const []));

  @override
  void send(String line) => _p.stdin.write(line);

  /// Closing stdin tells the hub to close all clients and exit.
  @override
  Future<void> close() async {
    try {
      await _p.stdin.close();
    } catch (_) {}
  }
}

class HubException implements Exception {
  HubException(this.message);
  final String message;
  @override
  String toString() => message;
}

class HubHost {
  const HubHost(this.id, this.name, {this.lan = const []});
  final String id;
  final String name;

  /// A's LAN addresses ("ip:port") as last heard, for 屏幕共享; empty when unknown.
  final List<String> lan;
}

class HubApp {
  const HubApp(this.app, this.name);
  final String app;
  final String name;
}

class AppList {
  const AppList(this.id, this.path, this.apps, {this.permissions});
  final String id;
  final String path;
  final List<HubApp> apps;

  /// A's `{"screen_recording","accessibility"}`; null when A does not report them.
  final Map<String, dynamic>? permissions;
}

class HubSession {
  const HubSession(this.sid, this.id, this.app, this.path, {this.port, this.token});
  final Object sid;
  final String id;
  final String app;
  final String path;

  /// Embedded sessions only: the local port the GUI connects to, and the one-time token.
  final int? port;
  final String? token;
}

class _Pending {
  _Pending(this.event);
  final String event; // the reply event that resolves this request
  final completer = Completer<Map<String, dynamic>>();
}

class HubClient extends ChangeNotifier {
  HubClient(this._t) {
    _sub = _t.lines.listen(_onLine, onDone: _onDone);
  }

  final HubTransport _t;
  late final StreamSubscription<String> _sub;
  final _pending = <int, _Pending>{};
  final _sessions = <Object, HubSession>{};
  var _nextReq = 1;

  List<HubHost> hosts = const [];
  bool alive = true;

  /// Last error not tied to a request (or the hub dying).
  String? lastError;

  /// The client's exit reason per closed session; the reader removes it.
  final closeReasons = <Object, String>{};

  List<HubSession> get sessions => List.unmodifiable(_sessions.values);

  Future<List<HubHost>> refreshHosts() async {
    await _request({'cmd': 'hosts'}, 'hosts');
    return hosts;
  }

  Future<HubHost> addHost(String id, String password) async {
    final m = await _request({'cmd': 'add_host', 'id': id, 'password': password}, 'host_added');
    return HubHost('${m['id'] ?? id}', '${m['name'] ?? ''}');
  }

  Future<List<HubHost>> removeHost(String id) async {
    await _request({'cmd': 'remove_host', 'id': id}, 'hosts');
    return hosts;
  }

  /// Points the hub at a moved data dir's `local/` (re-reads hosts.json).
  Future<void> setHome(String localDir) => _request({'cmd': 'set_home', 'dir': localDir}, 'home_set');

  Future<AppList> apps(String id) async {
    final m = await _request({'cmd': 'apps', 'id': id}, 'apps');
    final list = (m['apps'] as List? ?? const [])
        .whereType<Map>()
        .map((a) => HubApp('${a['app']}', '${a['name'] ?? a['app']}'))
        .toList();
    final perms = m['permissions'];
    return AppList('${m['id'] ?? id}', '${m['path'] ?? ''}', list,
        permissions: perms is Map ? Map<String, dynamic>.from(perms) : null);
  }

  Future<HubSession> open(String id, String app, {bool embed = false, bool reconnect = false}) async {
    final m = await _request(
        {'cmd': 'open', 'id': id, 'app': app, if (embed) 'embed': true, if (reconnect) 'reconnect': true}, 'opened');
    return _sessions[m['sid']] ?? _session(m);
  }

  /// [reason] is `user` when the person closed it (the hub only accepts that value).
  void close(Object sid, {String? reason}) => _send({'cmd': 'close', 'sid': sid, 'reason': ?reason});

  final _presence = <({String id, bool online})>[];

  /// The latest presence event of each device since the last call, oldest first; takes them and clears the queue.
  List<({String id, bool online})> takePresence() {
    final out = List<({String id, bool online})>.of(_presence);
    _presence.clear();
    return out;
  }
  void focus(Object sid) => _send({'cmd': 'focus', 'sid': sid});

  /// Tells the hub the GUI detached or re-attached a window ([what] is `detach` or `attach`); no reply.
  void note(Object sid, String what, int windows) =>
      _send({'cmd': 'note', 'sid': sid, 'what': what, 'windows': windows});

  Future<void> shutdown() async {
    await _t.close();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> cmd, String event) {
    if (!alive) return Future.error(HubException('rapp-hub is not running'));
    final req = _nextReq++;
    final p = _Pending(event);
    _pending[req] = p;
    _send({...cmd, 'req': req});
    return p.completer.future;
  }

  void _send(Map<String, dynamic> cmd) {
    if (!alive) return;
    try {
      _t.send(encodeLine(cmd));
    } catch (e) {
      lastError = 'write to rapp-hub failed: $e';
      notifyListeners();
    }
  }

  HubSession _session(Map<String, dynamic> m) =>
      HubSession(m['sid'] as Object, '${m['id'] ?? ''}', '${m['app'] ?? ''}', '${m['path'] ?? ''}',
          port: m['port'] is int ? m['port'] as int : null, token: m['token'] is String ? m['token'] as String : null);

  void _onLine(String line) {
    final m = decodeLine(line);
    if (m == null) return;
    final event = m['event'];
    switch (event) {
      case 'hosts':
        hosts = (m['hosts'] as List? ?? const [])
            .whereType<Map>()
            .map((h) => HubHost('${h['id']}', '${h['name'] ?? ''}',
                lan: [for (final a in (h['lan'] as List? ?? const [])) '$a']))
            .toList();
      case 'host_added':
        final id = '${m['id']}';
        hosts = [...hosts.where((h) => h.id != id), HubHost(id, '${m['name'] ?? ''}')];
      case 'opened':
        if (m['sid'] != null) _sessions[m['sid'] as Object] = _session(m);
      case 'presence':
        if (m['id'] != null) {
          // Only the latest word per device matters, and with no reader the queue must not grow.
          final id = '${m['id']}';
          _presence.removeWhere((p) => p.id == id);
          _presence.add((id: id, online: m['online'] == true));
        }
      case 'closed':
        _sessions.remove(m['sid']);
        if (m['sid'] != null && m['reason'] != null) closeReasons[m['sid'] as Object] = '${m['reason']}';
    }

    final p = _take(m, event);
    if (p != null) {
      if (event == 'error') {
        p.completer.completeError(HubException('${m['error'] ?? 'unknown error'}'));
      } else {
        p.completer.complete(m);
      }
    } else if (event == 'error') {
      lastError = '${m['error'] ?? 'unknown error'}';
    }
    notifyListeners();
  }

  /// Finds the request this event answers: by `req`, else the oldest pending
  /// request waiting for this event kind.
  _Pending? _take(Map<String, dynamic> m, Object? event) {
    final req = m['req'];
    if (req is int && _pending.containsKey(req)) return _pending.remove(req);
    if (event == 'error') return null;
    for (final e in _pending.entries) {
      if (e.value.event == event) return _pending.remove(e.key);
    }
    return null;
  }

  void _onDone() {
    alive = false;
    lastError = 'rapp-hub exited';
    for (final p in _pending.values) {
      p.completer.completeError(HubException('rapp-hub exited'));
    }
    _pending.clear();
    _sessions.clear();
    notifyListeners();
  }
}
