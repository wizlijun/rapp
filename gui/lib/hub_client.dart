// Talks to the rapp-hub child process over stdin/stdout JSON lines (spec §4).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'labels.dart';
import 'load_model.dart';
import 'log_view.dart';
import 'state/service_switch.dart';
import 'term/term_id.dart';

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

/// A restore that stopped part way: [ids] opened before [message] stopped it.
class RestoreStopped extends HubException {
  RestoreStopped(super.message, this.ids);
  final List<String> ids;
}

class HubHost {
  const HubHost(this.id, this.name, {this.lan = const [], this.route, this.os, this.fp});
  final String id;
  final String name;

  /// A's LAN addresses ("ip:port") as last heard, for 屏幕共享; empty when unknown.
  final List<String> lan;

  /// `relay` when this host is forced onto the relay; null is automatic.
  final String? route;

  bool get forcedRelay => route == 'relay';

  /// What system A last said it is (`macos`, `omarchy`, …), as the hub kept it; null when never heard.
  final String? os;

  /// The host's fingerprint, as the hub knows it; null when never heard.
  final String? fp;
}

/// One of A's screens, as the `desktop:` entry of its app list names them (main first).
class RemoteDisplay {
  const RemoteDisplay(this.id, this.name, {required this.main, required this.width, required this.height});
  final String id;
  final String name;
  final bool main;
  final int width;
  final int height;

  static RemoteDisplay? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = v['id'], w = v['width'], h = v['height'];
    if (id is! String || id.isEmpty || w is! int || h is! int) return null;
    final name = v['name'];
    return RemoteDisplay(id, name is String ? name : '', main: v['main'] == true, width: w, height: h);
  }
}

class HubApp {
  const HubApp(this.app, this.name, {this.displays = const []});
  final String app;
  final String name;

  /// A's screens; empty except on `desktop:`.
  final List<RemoteDisplay> displays;
}

/// A `version` or `os` field: a non-empty string, else none.
String? _word(Object? v) => v is String && v.isNotEmpty ? v : null;

class AppList {
  const AppList(this.id, this.path, this.apps, {this.permissions, this.capabilities, this.version, this.os});
  final Map<String, dynamic>? capabilities;

  /// A's rApp version; null from a host older than version labels.
  final String? version;

  /// What system A is; null from a host older than system marks.
  final String? os;
  final String id;
  final String path;
  final List<HubApp> apps;

  /// A's `{"screen_recording","accessibility"}`; null when A does not report them.
  final Map<String, dynamic>? permissions;
}

/// One terminal session of a device (`terms` event, spec §6). [host] is null on the device itself.
class TermRow {
  const TermRow(this.id, this.name, this.command, this.host, this.panes, this.attached, this.activity, this.dead,
      this.unread, {this.ps, this.title, this.fg, this.shell});
  final String id, name, command;
  final String? host;
  final int panes, attached;

  /// Unix seconds of the last output.
  final int activity;
  final bool dead, unread;

  /// The program status the session reports (OSC 7501); null when it reports none or something unrecognised.
  final TermPs? ps;

  /// The title the program set (OSC 0/2); null when it set none or the session was named by hand.
  final String? title;

  /// The name of the program in front (`vim`, `zsh`); null from an old device.
  final String? fg;

  /// Whether the program in front is the shell the session started; null from an old device, which cannot end the
  /// session either (the gate for 「结束终端」).
  final bool? shell;

  /// What to show for the session: the program's title, else its name.
  String get shown => title ?? name;
}

/// What a program in a terminal session says it is doing (spec §5.5).
class TermPs {
  const TermPs(this.state, {this.kind, this.app, this.msg, this.progress, this.since = 0, this.stopped = 0, this.seq = 0});
  final String state;
  final String? kind, app, msg;

  /// 0-100, else null.
  final int? progress;
  final int since, stopped, seq;
}

const _psStates = {'idle', 'working', 'done', 'error', 'blocked'};

/// A row's `ps`: null unless it is a map with one of the five known states.
TermPs? termPs(Object? v) {
  if (v is! Map) return null;
  final state = v['state'];
  if (state is! String || !_psStates.contains(state)) return null;
  final p = v['progress'];
  return TermPs(state,
      kind: _str(v['kind']),
      app: _str(v['app']),
      msg: _str(v['msg']),
      progress: p is int && p >= 0 && p <= 100 ? p : null,
      since: _int(v['since']),
      stopped: _int(v['stopped']),
      seq: _int(v['seq']));
}

/// The place sessions are listed from: the device itself (`host` null). An old device may also list SSH hosts; those
/// rows are dropped.
class TermHost {
  const TermHost(this.host, {this.launchers = const [], this.shells, this.saved = const []});
  final String? host;

  /// The local host row only: text terminals saved from an earlier run that are not alive now, in the order the
  /// device sent them. An old device sends none. No directory or command ever comes with them.
  final List<TermSaved> saved;

  /// The local host row only: the terminal apps the device can open a text terminal in.
  final List<String> launchers;

  /// The shells the device can open, the default marked; null when the row has no `shells` (an old device).
  final List<TermShell>? shells;
}

/// A text terminal saved from an earlier run that can be restored; [saved] is Unix seconds, [boot] says it was saved
/// before the device last started.
class TermSaved {
  const TermSaved(this.key, this.name, {this.prog, this.saved = 0, this.boot = false});
  final String key, name;
  final String? prog;
  final int saved;
  final bool boot;
}

/// A shell the device can open a text terminal with.
class TermShell {
  const TermShell(this.name, this.path, this.isDefault);
  final String name, path;
  final bool isDefault;
}

/// A device's terminal sessions as the hub last said; [off] means the device has them turned off.
class TermList {
  const TermList(this.id, {this.path, this.error, this.off = false, this.terms = const [], this.hosts = const []});
  final String id;
  final String? path, error;
  final bool off;
  final List<TermRow> terms;
  final List<TermHost> hosts;
}

int _int(Object? v) => v is num ? v.toInt() : 0;
String? _str(Object? v) => v is String ? v : null;

TermList _termList(Map<String, dynamic> m, String fallbackId) {
  final id = '${m['id'] ?? fallbackId}';
  if (m['off'] == true) return TermList(id, off: true);
  if (m['error'] != null) return TermList(id, error: '${m['error']}');
  return TermList(
    id,
    path: _str(m['path']),
    terms: [
      for (final r in (m['terms'] as List? ?? const []).whereType<Map>())
        if (parseTermId('${r['id']}')?.backend == 'pty')
          TermRow('${r['id']}', '${r['name'] ?? ''}', '${r['command'] ?? ''}', _str(r['host']), _int(r['panes']),
            _int(r['attached']), _int(r['activity']), r['dead'] == true, r['unread'] == true,
            ps: termPs(r['ps']), title: switch (r['title']) { String s when s.isNotEmpty => s, _ => null },
            fg: switch (r['fg']) { String s when s.isNotEmpty => s, _ => null }, shell: switch (r['shell']) { bool b => b, _ => null }),
    ],
    hosts: [
      for (final h in (m['hosts'] as List? ?? const []).whereType<Map>())
        if (h['host'] == null)
          TermHost(null,
              launchers: [for (final l in (h['launchers'] as List? ?? const [])) if (l is String) l],
              shells: h['shells'] is List
                  ? [
                      for (final x in (h['shells'] as List).whereType<Map>())
                        if (x['name'] is String && x['path'] is String) TermShell(x['name'], x['path'], x['default'] == true),
                    ]
                  : null,
              saved: [
                for (final x in (h['saved'] as List? ?? const []).whereType<Map>())
                  if (x['key'] is String && x['name'] is String)
                    TermSaved(x['key'], x['name'], prog: _str(x['prog']), saved: _int(x['saved']), boot: x['boot'] == true),
              ]),
    ],
  );
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

/// The hub's `access` event (iOS, where the hub owns `service.json`): the relay, whether a key is set, and the
/// name this device introduces itself with. The key itself never comes back.
class HubAccess {
  const HubAccess(this.relay, this.hasKey, this.name);
  final String? relay;
  final bool hasKey;
  final String name;

  static HubAccess fromJson(Map<String, dynamic> m) =>
      HubAccess(m['relay'] is String ? m['relay'] as String : null, m['has_key'] == true, '${m['name'] ?? ''}');

  @override
  bool operator ==(Object other) =>
      other is HubAccess && other.relay == relay && other.hasKey == hasKey && other.name == name;

  @override
  int get hashCode => Object.hash(relay, hasKey, name);

  @override
  String toString() => 'HubAccess($relay, $hasKey, $name)';
}

class _Pending {
  _Pending(this.event);
  final String event; // the reply event that resolves this request
  final completer = Completer<Map<String, dynamic>>();
}

typedef PortMap = ({String id, int port, int local, String? kind});

/// Where this device reaches the center service (rapp-center) through a share: the one with the smallest device id (the ids are
/// fixed-width). Null when no share is of that kind.
String? stateUrlFromPorts(List<PortMap> maps) {
  final best = stateMapOf(maps);
  return best == null ? null : 'http://localhost:${best.local}';
}

/// The share of the center service (rapp-center) this device uses: the `state` one with the smallest device id; null if none.
PortMap? stateMapOf(List<PortMap> maps) {
  PortMap? best;
  for (final p in maps) {
    if (p.kind != 'state') continue;
    if (best == null || p.id.compareTo(best.id) < 0) best = p;
  }
  return best;
}

class HubClient extends ChangeNotifier implements ServiceSwitchApi {
  HubClient(this._t) {
    _sub = _t.lines.listen(_onLine, onDone: _onDone);
  }

  final HubTransport _t;
  late final StreamSubscription<String> _sub;
  final _pending = <int, _Pending>{};
  final _sessions = <Object, HubSession>{};
  var _nextReq = 1;

  List<HubHost> hosts = const [];

  /// This app's own fingerprint and device name, from the last `hosts` event that carried them.
  String? meFp;
  String? meName;

  /// The share maps of the last `ports` event (the whole list each time); `kind` is `state` for the center service (rapp-center).
  List<PortMap> portMaps = const [];
  bool alive = true;

  /// The hub's rApp version (the same install as this GUI), from its `hosts` events; null until
  /// one carries it.
  String? version;

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

  /// The app came back or the network changed (Wi-Fi, cellular): the hub takes a new UDP socket and asks
  /// every device and the relay again at once; no reply.
  void netChanged() => _send({'cmd': 'net_changed'});

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

  /// The last `access` event; null until one arrived.
  HubAccess? lastAccess;

  /// The last 4 characters of the key [setAccess] saved in this run, for 本机's 显示; never the whole key.
  String? keyTail;

  /// The relay and key state as the hub reads `service.json` (iOS only; elsewhere the service owns them).
  Future<HubAccess> access() async => HubAccess.fromJson(await _request({'cmd': 'access'}, 'access'));

  /// Saves [relay] and [key] in `service.json` and dials again; the hub's refusal (`missing relay`, `bad key`) is
  /// thrown with its words.
  Future<HubAccess> setAccess(String relay, String key) async {
    final a = HubAccess.fromJson(await _request({'cmd': 'set_access', 'relay': relay, 'key': key}, 'access'));
    final k = key.trim();
    keyTail = k.length <= 4 ? null : k.substring(k.length - 4);
    return a;
  }

  /// Pauses or resumes the hub's presence probe (iOS in the background); no reply.
  void pausePresence(bool paused) => _send({'cmd': 'presence', 'paused': paused});

  Future<AppList> apps(String id) async {
    final m = await _request({'cmd': 'apps', 'id': id}, 'apps');
    final list = (m['apps'] as List? ?? const [])
        .whereType<Map>()
        .map((a) => HubApp('${a['app']}', '${a['name'] ?? a['app']}', displays: [
              if (a['displays'] is List)
                for (final d in a['displays'] as List) ?RemoteDisplay.fromJson(d),
            ]))
        .toList();
    final perms = m['permissions'];
    return AppList('${m['id'] ?? id}', '${m['path'] ?? ''}', list,
        permissions: perms is Map ? Map<String, dynamic>.from(perms) : null,
        capabilities: m['capabilities'] is Map ? Map<String, dynamic>.from(m['capabilities']) : null,
        version: _word(m['version']),
        os: _word(m['os']));
  }

  /// The 日志 screen's query, on this machine or on host [id]. An old peer answers `unknown op`.
  Future<LogPage> logs({String? id, required LogQuery query}) async =>
      LogPage.fromJson(await _request({'cmd': 'logs', 'id': ?id, ...query.toJson()}, 'logs'));

  /// Each device's latest terminal list, from a `terms` answer or the watch stream.
  final termLists = <String, TermList>{};

  Future<TermList> terms(String id) async {
    final m = await _request({'cmd': 'terms', 'id': id}, 'terms');
    return termLists[id] ?? _termList(m, id);
  }

  /// Each online device's load from its watch (device-load spec §10); a device that went offline, is too old or
  /// is removed has none. Never a stale number: `gone`, `unsupported` and a stream `error` drop it (a watch that
  /// just stops sending is [MainState.columnLoad]'s to leave out).
  final loads = <String, DeviceLoad>{};

  /// Device [id]'s load once, as the hub answers `load` (`ok` stripped); [top] asks for the process list too. The
  /// device's refusal (`unknown op`, `no data`) is thrown.
  Future<Map<String, dynamic>> loadNow(String id, {bool top = false}) =>
      _request({'cmd': 'load', 'id': id, if (top) 'top': true}, 'load');

  /// Opens a text terminal window on device [id] running [shell] (the device's default when null, and an old device
  /// is sent none) in terminal app [app]; answers the new term id. [from]: the terminal it is opened beside (its
  /// directory and shell, its window); an old device ignores it. [labelFrom]: a terminal that is gone, whose label
  /// the new one takes over.
  Future<String> openTerm(String id, {String? shell, required String app, String? from, String? labelFrom}) async {
    final m = await _request(
        {'cmd': 'open_term', 'id': id, 'shell': ?shell, 'app': app, 'from': ?from, 'label_from': ?labelFrom},
        'term_created');
    return '${m['term']}';
  }

  /// Each device's session labels, as its watch last pushed them; none yet for a device whose table has not come.
  final labels = <String, LabelTable>{};

  /// Devices that predate labels: no label can be shown or changed there.
  final labelsUnsupported = <String>{};

  /// Devices whose next table is taken whatever its rev (their watch ended: the device may have started over).
  final _labelsAfresh = <String>{};

  /// Labels session [app] of device [id]; both empty clears it. The device's refusal is thrown with its words.
  Future<void> setLabel(String id, String app, {required String title, required String note}) =>
      _request({'cmd': 'set_label', 'id': id, 'app': app, 'title': title, 'note': note}, 'label_set');

  /// Clears session [app]'s label on device [id].
  Future<void> resetLabel(String id, String app) => _request({'cmd': 'reset_label', 'id': id, 'app': app}, 'label_reset');

  void _onLabels(Map<String, dynamic> m) {
    final id = m['id'];
    if (id is! String) return;
    if (m['unsupported'] == true) {
      labelsUnsupported.add(id);
      labels.remove(id);
      return;
    }
    if (m['labels'] == null) {
      // The watch ended (it is retried): what was shown stays until the next table.
      _labelsAfresh.add(id);
      return;
    }
    final t = LabelTable.fromJson(m);
    final had = labels[id];
    // An older table is a late one, unless the watch started over (`first`: the device may have a fresh file).
    if (had != null && t.rev < had.rev && m['first'] != true && !_labelsAfresh.contains(id)) return;
    _labelsAfresh.remove(id);
    labelsUnsupported.remove(id);
    labels[id] = t;
  }

  /// Ends text terminal [term] of device [id] for good (its program too); the refusal is thrown with its words.
  /// Refreshes the device's list afterwards.
  Future<void> endTerm(String id, String term) async {
    await _request({'cmd': 'end_term', 'id': id, 'term': term}, 'term_ended');
    try {
      await terms(id);
    } catch (_) {}
  }

  /// Reopens the saved text terminals [keys] of device [id] in terminal app [app]; answers the new term ids, in the
  /// order opened. [keys] must be explicit (an empty list would make the hub wait for one terminal only). The device's
  /// refusal is thrown with its words. Refreshes the device's list afterwards.
  Future<List<String>> restoreTerms(String id, List<String> keys, {required String app}) async {
    try {
      final m = await _request({'cmd': 'restore_terms', 'id': id, 'keys': keys, 'app': app}, 'terms_restored');
      final ids = [for (final x in (m['terms'] as List? ?? const [])) '$x'];
      if (m['error'] case final String e) throw RestoreStopped(e, ids);
      return ids;
    } finally {
      try {
        await terms(id);
      } catch (_) {}
    }
  }

  /// Forgets the saved text terminals [keys] of device [id] for good. Refreshes the device's list afterwards.
  Future<void> forgetTerms(String id, List<String> keys) async {
    await _request({'cmd': 'forget_terms', 'id': id, 'keys': keys}, 'terms_forgotten');
    try {
      await terms(id);
    } catch (_) {}
  }

  /// Renames text terminal [term] of device [id] to [name] (already cleaned); the device's refusal is thrown with
  /// its words. Refreshes the device's list afterwards so the new name shows.
  Future<void> renameTerm(String id, String term, String name) async {
    await _request({'cmd': 'rename_term', 'id': id, 'term': term, 'name': name}, 'term_renamed');
    try {
      await terms(id);
    } catch (_) {}
  }

  /// Turns the state service of device [to] on or off (without [on]: asks its status); answers the device's reply.
  /// iOS has no service of its own, so [to] is required. The device's refusal is thrown with its words.
  @override
  Future<Map<String, Object?>> stateService({String? to, bool? on}) async {
    if (to == null) throw ArgumentError.notNull('to');
    final m = await _request({'cmd': 'set_service', 'id': to, 'name': 'state', 'on': ?on}, 'service');
    final r = m['reply'];
    return r is Map ? Map<String, Object?>.from(r) : <String, Object?>{};
  }

  @override
  Future<String?> stateHost() async => stateMapOf(portMaps)?.id;

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
        version = _word(m['version']);
        meFp = _word(m['me']) ?? meFp;
        meName = _word(m['name']) ?? meName;
        hosts = (m['hosts'] as List? ?? const [])
            .whereType<Map>()
            .map((h) => HubHost('${h['id']}', '${h['name'] ?? ''}',
                lan: [for (final a in (h['lan'] as List? ?? const [])) '$a'],
                route: h['route'] is String ? h['route'] as String : null,
                os: _word(h['os']),
                fp: _word(h['fp'])))
            .toList();
        // A removed host's link is gone with it.
        final ids = {for (final h in hosts) h.id};
        hostPaths.removeWhere((id, _) => !ids.contains(id));
        _paths.removeWhere((p) => !ids.contains(p.id));
      case 'ports':
        portMaps = [
          for (final i in (m['maps'] as List? ?? const []))
            if (i is Map && i['id'] != null && i['port'] is int && i['local'] is int)
              (id: '${i['id']}', port: i['port'] as int, local: i['local'] as int, kind: i['kind'] is String ? i['kind'] as String : null),
        ];
      case 'host_added':
        final id = '${m['id']}';
        // Added again: its route, LAN addresses and system stay until the next hosts list says otherwise.
        final was = hosts.where((h) => h.id == id).firstOrNull;
        hosts = [
          ...hosts.where((h) => h.id != id),
          HubHost(id, '${m['name'] ?? ''}', lan: was?.lan ?? const [], route: was?.route, os: was?.os, fp: was?.fp),
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
      case 'access':
        lastAccess = HubAccess.fromJson(m);
      case 'home_set':
        // A new data dir: the hub dropped every link it had.
        hostPaths.clear();
        _paths.clear();
        loads.clear();
      case 'terms':
        if (m['id'] != null) termLists['${m['id']}'] = _termList(m, '${m['id']}');
      case 'load' when m['req'] is! int && m['id'] != null:
        _onLoad('${m['id']}', m);
      case 'labels':
        _onLabels(m);
      case 'closed':
        _sessions.remove(m['sid']);
        if (m['sid'] != null && m['reason'] != null) closeReasons[m['sid'] as Object] = '${m['reason']}';
    }

    // A watch event has no `req`: it answers no one (`_take` would give it to another device's `terms`, `labels` or `load`).
    final p = (event == 'terms' || event == 'labels' || event == 'load') && m['req'] is! int ? null : _take(m, event);
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

  /// One line of device [id]'s load watch: the first (with `history`) starts it, the next ones move it on; `gone`,
  /// `unsupported` and a stream `error` drop it. The hub retries an error after 30 s, up to 10 min apart: its first
  /// line then starts the load again.
  void _onLoad(String id, Map<String, dynamic> m) {
    if (m['gone'] == true || m['unsupported'] == true || m['error'] != null) {
      loads.remove(id);
    } else {
      final was = loads[id];
      loads[id] = was == null || m.containsKey('history') ? DeviceLoad.fromJson(m) : was.next(m);
    }
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
    loads.clear();
    net = null;
    notifyListeners();
  }
}
