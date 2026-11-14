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
  const HubHost(this.id, this.name, {this.lan = const [], this.route});
  final String id;
  final String name;

  /// A's LAN addresses ("ip:port") as last heard, for 屏幕共享; empty when unknown.
  final List<String> lan;

  /// `relay` when this host is forced onto the relay; null is automatic.
  final String? route;

  bool get forcedRelay => route == 'relay';
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

/// The hub's level of its link to the relay (spec 2026-11-14-rapp-network-status §3.4).
enum NetLevel { strong, ok, weak, down }

/// The hub's last `net` event: the link to the relay, measured.
class NetStatus {
  const NetStatus(this.level, this.rttMs, this.loss);
  final NetLevel level;

  /// The round trip to the relay; null when nothing answered lately.
  final int? rttMs;

  /// Lost share, 0 to 1.
  final double loss;

  @override
  bool operator ==(Object other) =>
      other is NetStatus && other.level == level && other.rttMs == rttMs && other.loss == loss;

  @override
  int get hashCode => Object.hash(level, rttMs, loss);

  @override
  String toString() => 'NetStatus($level, $rttMs, $loss)';
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

  /// The link to the relay as last pushed; null when no relay is set or nothing is known yet.
  NetStatus? net;

  /// Asks the hub for the `net` event as it stands (sent once the GUI is attached, §7).
  void askNet() => _send({'cmd': 'net'});

  /// Starts or stops the hub asking the relay whether host [id] came online (§5.3 rule 3); no reply.
  void watch(String id, bool on) => _send({'cmd': 'watch', 'id': id, 'on': on});

  /// A session's path looks broken: the hub probes the relay now.
  void netSuspect() => _send({'cmd': 'net_suspect'});

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

  /// Sets [route] (`relay` or `auto`) for host [id]; resolves once the hub answers with the hosts list.
  Future<void> setRoute(String id, String route) => _request({'cmd': 'set_route', 'id': id, 'route': route}, 'hosts');

  /// Tells the hub moving a session of [id] onto its new link failed; no reply.
  void routeFailed(String id) => _send({'cmd': 'route_failed', 'id': id});

  final _presence = <({String id, bool online, String? error})>[];

  /// The latest presence event of each device since the last call, oldest first; takes them and clears the queue.
  /// [error] is the hub's reason, only on an offline event.
  List<({String id, bool online, String? error})> takePresence() {
    final out = List<({String id, bool online, String? error})>.of(_presence);
    _presence.clear();
    return out;
  }

  /// The path (`lan`, `direct`, `relay`) of the link the hub last cached per host.
  final hostPaths = <String, String>{};
  final _paths = <({String id, String path})>[];

  /// The latest path event of each host since the last call, oldest first; takes them and clears the queue.
  List<({String id, String path})> takePaths() {
    final out = List<({String id, String path})>.of(_paths);
    _paths.clear();
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
                lan: [for (final a in (h['lan'] as List? ?? const [])) '$a'],
                route: h['route'] is String ? h['route'] as String : null))
            .toList();
        // A removed host's link is gone with it.
        final ids = {for (final h in hosts) h.id};
        hostPaths.removeWhere((id, _) => !ids.contains(id));
        _paths.removeWhere((p) => !ids.contains(p.id));
      case 'host_added':
        final id = '${m['id']}';
        // Added again: its route and LAN addresses stay until the next hosts list says otherwise.
        final was = hosts.where((h) => h.id == id).firstOrNull;
        hosts = [
          ...hosts.where((h) => h.id != id),
          HubHost(id, '${m['name'] ?? ''}', lan: was?.lan ?? const [], route: was?.route),
        ];
      case 'opened':
        if (m['sid'] != null) _sessions[m['sid'] as Object] = _session(m);
      case 'presence':
        if (m['id'] != null) {
          // Only the latest word per device matters, and with no reader the queue must not grow.
          final id = '${m['id']}';
          _presence.removeWhere((p) => p.id == id);
          final online = m['online'] == true;
          _presence.add((id: id, online: online, error: online || m['error'] == null ? null : '${m['error']}'));
        }
      case 'path':
        if (m['id'] != null && m['path'] is String) {
          final id = '${m['id']}';
          final path = m['path'] as String;
          hostPaths[id] = path;
          _paths.removeWhere((p) => p.id == id);
          _paths.add((id: id, path: path));
        }
      case 'net':
        final level = NetLevel.values.where((l) => l.name == m['level']).firstOrNull;
        final rtt = m['rtt_ms'];
        final loss = m['loss'];
        net = level == null ? null : NetStatus(level, rtt is num ? rtt.round() : null, loss is num ? loss.toDouble() : 0);
      case 'home_set':
        // A new data dir: the hub dropped every link it had.
        hostPaths.clear();
        _paths.clear();
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
    hostPaths.clear();
    _paths.clear();
    net = null;
    notifyListeners();
  }
}
