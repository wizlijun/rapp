// Local IPC to rapp-service: TCP 127.0.0.1:21119, token line first (spec §3).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

const servicePort = 21119;

class ServiceException implements Exception {
  ServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ServiceSession {
  const ServiceSession(this.sid, this.peer, this.app, this.path, this.since);
  final Object sid;
  final String peer;
  final String app;
  final String path;
  final Object? since;
}

class ServiceStatus {
  const ServiceStatus({
    this.id,
    this.name = '',
    this.password = '',
    this.relay = 'off',
    this.relayError,
    this.screenRecording = false,
    this.accessibility = false,
    this.sessions = const [],
    this.lanIds = const [],
  });

  final String? id;
  final String name;
  final String password;
  final String relay; // connected | connecting | off
  final String? relayError;
  final bool screenRecording;
  final bool accessibility;
  final List<ServiceSession> sessions;

  /// `id@ip[:port]`, one per local IPv4 (§3): what B types when there is no relay.
  final List<String> lanIds;

  /// The ID as people should type it: the bare ID once the relay is connected,
  /// otherwise the `id@ip` forms (bare ID if the machine has no address).
  List<String> get shownIds =>
      relay == 'connected' || lanIds.isEmpty ? [?id] : lanIds;

  factory ServiceStatus.fromJson(Map<String, dynamic> m) {
    final perms = m['permissions'] is Map ? m['permissions'] as Map : const {};
    return ServiceStatus(
      id: m['id']?.toString(),
      name: '${m['name'] ?? ''}',
      password: '${m['password'] ?? ''}',
      relay: '${m['relay'] ?? 'off'}',
      relayError: m['relay_error']?.toString(),
      screenRecording: perms['screen_recording'] == true,
      accessibility: perms['accessibility'] == true,
      lanIds: (m['lan_ids'] as List? ?? const []).map((e) => '$e').toList(),
      sessions: (m['sessions'] as List? ?? const [])
          .whereType<Map>()
          .map((s) => ServiceSession(s['sid'] as Object, '${s['peer'] ?? ''}', '${s['app'] ?? ''}',
              '${s['path'] ?? ''}', s['since']))
          .toList(),
    );
  }
}

/// One authenticated IPC connection. Replies come back in request order;
/// lines carrying `event` go to [events].
class ServiceConnection {
  ServiceConnection._(this._s) {
    _s.done.then((_) {}, onError: (_) {}); // write errors surface via the read side
    _s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
          _onLine,
          onError: (_) => _fail(),
          onDone: _fail,
          cancelOnError: true,
        );
  }

  final Socket _s;
  final _waiting = <Completer<Map<String, dynamic>>>[];
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _done = Completer<void>();
  var _closed = false;

  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Completes when the service closes the connection.
  Future<void> get done => _done.future;

  static Future<ServiceConnection> connect({
    required String token,
    String host = '127.0.0.1',
    int port = servicePort,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.setOption(SocketOption.tcpNoDelay, true);
    final c = ServiceConnection._(s);
    s.write('${jsonEncode({'token': token})}\n');
    return c;
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> cmd) {
    if (_closed) return Future.error(ServiceException('service connection closed'));
    final c = Completer<Map<String, dynamic>>();
    _waiting.add(c);
    _s.write('${jsonEncode(cmd)}\n');
    return c.future;
  }

  Future<ServiceStatus> status() async => ServiceStatus.fromJson(await request({'cmd': 'status'}));
  Future<void> setPassword(String password) => request({'cmd': 'set_password', 'password': password});
  Future<void> setRelay(String relay, String key) => request({'cmd': 'set_relay', 'relay': relay, 'key': key});
  Future<void> kick(Object sid) => request({'cmd': 'kick', 'sid': sid});
  Future<void> subscribe() => request({'cmd': 'subscribe'});

  void _onLine(String line) {
    Map<String, dynamic> m;
    try {
      final v = jsonDecode(line);
      if (v is! Map<String, dynamic>) return;
      m = v;
    } on FormatException {
      return;
    }
    if (m.containsKey('event')) {
      _events.add(m);
      return;
    }
    if (_waiting.isEmpty) return;
    final c = _waiting.removeAt(0);
    if (m['ok'] == true) {
      c.complete(m);
    } else {
      c.completeError(ServiceException('${m['error'] ?? 'request failed'}'));
    }
  }

  void _fail() {
    if (_closed) return;
    _closed = true;
    for (final c in _waiting) {
      c.completeError(ServiceException('service connection closed'));
    }
    _waiting.clear();
    _events.close();
    _done.complete();
    _s.destroy();
  }

  Future<void> close() async => _fail();
}

/// Keeps a live view of the service: connects (retrying), subscribes,
/// and re-reads status on every `changed` event.
class ServiceMonitor extends ChangeNotifier {
  ServiceMonitor({
    required this.readToken,
    this.port = servicePort,
    this.retry = const Duration(seconds: 2),
  });

  /// Reads `ipc.token`; null when the file is missing.
  final Future<String?> Function() readToken;
  final int port;
  final Duration retry;

  ServiceStatus? status;
  String? error;
  bool get running => status != null;

  ServiceConnection? _cmd;
  ServiceConnection? _sub;
  Timer? _timer;
  var _disposed = false;
  var _connecting = false;

  void start() => _connect();

  Future<void> _connect() async {
    if (_disposed || _connecting) return;
    _connecting = true;
    try {
      final token = await readToken();
      if (token == null || token.isEmpty) throw ServiceException('no ipc.token');
      final cmd = await ServiceConnection.connect(token: token, port: port);
      final sub = await ServiceConnection.connect(token: token, port: port);
      _cmd = cmd;
      _sub = sub;
      await sub.subscribe();
      sub.events.listen((e) {
        if (e['event'] == 'changed') refresh();
      });
      cmd.done.then((_) => _lost());
      sub.done.then((_) => _lost());
      status = await cmd.status();
      error = null;
      if (_disposed) return _closeAll();
      notifyListeners();
    } catch (e) {
      _closeAll();
      status = null;
      error = e is SocketException ? 'service not running' : '$e';
      if (!_disposed) {
        notifyListeners();
        _schedule();
      }
    } finally {
      _connecting = false;
    }
  }

  Future<void> refresh() async {
    final c = _cmd;
    if (c == null) return;
    try {
      status = await c.status();
      if (!_disposed) notifyListeners();
    } catch (_) {
      // _lost handles a dead connection.
    }
  }

  void _lost() {
    if (_disposed || (_cmd == null && _sub == null)) return;
    _closeAll();
    status = null;
    error = 'service not running';
    notifyListeners();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(retry, _connect);
  }

  void _closeAll() {
    final c = _cmd, s = _sub;
    _cmd = null;
    _sub = null;
    c?.close();
    s?.close();
  }

  ServiceConnection _need() => _cmd ?? (throw ServiceException('service not running'));

  Future<void> setPassword(String pw) async {
    await _need().setPassword(pw);
    await refresh();
  }

  Future<void> setRelay(String relay, String key) async {
    await _need().setRelay(relay, key);
    await refresh();
  }

  Future<void> kick(Object sid) async {
    await _need().kick(sid);
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _closeAll();
    super.dispose();
  }
}

/// Token reader for the real config dir.
Future<String?> Function() tokenFileReader(String configDir) => () async {
      final f = File('$configDir${Platform.pathSeparator}ipc.token');
      if (!await f.exists()) return null;
      return (await f.readAsString()).trim();
    };
