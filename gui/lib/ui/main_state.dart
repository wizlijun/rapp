// The single source of UI state for the main window.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';

import '../embed/remote_session.dart';
import '../embed/session_port.dart';
import '../embed/stream_choice.dart';
import '../hub_client.dart';
import '../permissions.dart';
import 'lamp.dart';
import 'lifecycle.dart';
import 'prefs.dart';
import 'session_model.dart';
import 'tokens.dart';

export 'lifecycle.dart' show hubWord, hubWords;

enum PanelTab { sessions, devices }

class DeviceProbe {
  DeviceProbe(this.lamp, this.word, {this.apps, this.error});
  Lamp lamp;
  String word;
  AppList? apps;
  String? error;
}

class MainState extends ChangeNotifier {
  MainState({
    required this.hub,
    this.hubError,
    required this.configDir,
    required this.prefs,
    this.port,
    this.doubleClick = const Duration(milliseconds: 500),
  }) {
    _portSub = port?.events.listen(_onPortEvent);
    hub?.addListener(_onHub);
    _lastError = hub?.lastError;
    _entries = _mapEntries();
    refreshDevices();
  }

  final HubClient? hub;
  final String? hubError;
  final String configDir;
  final UiPrefs prefs;
  final SessionPort? port;

  /// The double-click interval the runner reported (`init`), for counting clicks (R14).
  final Duration doubleClick;
  StreamSubscription<SessionEvent>? _portSub;

  /// Embedded sessions by hub sid.
  final Map<Object, RemoteSession> remote = {};

  /// Embedded sessions by `id/app`, in the order they were first opened. A record outlives its
  /// link: a disconnected one stays here, with its last frame, until the user ends it.
  final Map<String, SessionRecord> _records = {};
  int _seq = 0;
  // Hub closed first: waiting up to 1 s for the runner's reason.
  final Map<Object, _Waiting> _waiting = {};
  // Sids closed on the hub without ever being shown; their hub `closed` is ignored.
  final Set<Object> _quiet = {};

  bool get embeds => port != null;

  SessionRecord? recordFor(String key) => _records[key];
  SessionRecord? get currentRecord => currentKey == null ? null : _records[currentKey];
  bool get currentDisconnected => currentRecord?.phase == Phase.disconnected;

  /// What the stage shows of [r]: the last picture while it reconnects, else its own session.
  RemoteSession? _stageRemote(SessionRecord r) {
    final sid = r.lastSid ?? r.sid;
    return sid == null ? null : remote[sid];
  }

  RemoteSession? get currentRemote {
    final r = currentRecord;
    return r == null ? null : _stageRemote(r);
  }

  SessionRecord? _recordOfSid(Object sid) {
    for (final r in _records.values) {
      if (r.sid == sid) return r;
    }
    return null;
  }

  SessionRecord? _recordOfLastSid(Object sid) {
    for (final r in _records.values) {
      if (r.lastSid == sid) return r;
    }
    return null;
  }

  /// Whether [sid] is the live session of a record: only then do the runner or the hub hear of it (R12).
  bool _liveSid(Object sid) => _recordOfSid(sid)?.phase == Phase.live;

  bool _hubHas(Object sid) => hub != null && hub!.sessions.any((s) => s.sid == sid);

  /// Whether [r] is live and the hub still has its session: the only case that talks to either.
  bool _reachable(SessionRecord r) => r.phase == Phase.live && r.sid != null && _hubHas(r.sid!);

  /// Bytes per second over all live embedded sessions (R24).
  int get totalBytesPerSecond {
    var n = 0;
    for (final r in _records.values) {
      if (r.phase == Phase.live && r.sid != null) n += remote[r.sid]?.bytesPerSecond ?? 0;
    }
    return n;
  }

  int get disconnectedCount => _records.values.where((r) => r.phase == Phase.disconnected).length;

  PanelTab? panel;
  Grouping grouping = Grouping.device;
  String? currentKey;
  String hint = '';
  final Map<String, DeviceProbe> probes = {};
  String? deviceTab;

  final Map<String, SessionEntry> _pending = {};
  late List<SessionEntry> _entries;
  String? _lastError;
  final Map<String, String> _appNames = {};
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    if (embeds) _entries = _mapEntries();
    // Focus never stays on a session that is no longer current.
    if (pictureFocused != null && current?.sid != pictureFocused) _blur();
    _syncPolicy();
    // Every change of the current session or of detach state ends in a notify.
    _applyFps();
    super.notifyListeners();
  }

  // ---- picture focus (R15, R24) ----
  /// The session whose picture has keyboard focus: its keys go to A (the runner routes them).
  Object? pictureFocused;

  /// A press on [sid]'s picture: keys go to A from now on.
  void focusPicture(Object sid) {
    if (pictureFocused == sid || !_liveSid(sid)) return;
    pictureFocused = sid;
    port?.pictureFocus(sid);
    notifyListeners();
  }

  /// A press outside the picture (top bar, overlays): keys stay with rapp.
  void blurPicture() {
    if (_blur()) notifyListeners();
  }

  bool _blur() {
    if (pictureFocused == null) return false;
    pictureFocused = null;
    port?.pictureFocus(null);
    return true;
  }

  // ---- stage size (Ruling P2) ----
  Size? _lastStage;
  RemoteSession? _syncedRs;

  /// The picture's rect in global coordinates; the IRON MAN grid leaves it out (R25).
  final ValueNotifier<Rect?> pictureHole = ValueNotifier(null);

  /// The stage is [s] big now. Remembered, and given to the current session's resize policy.
  void stageSize(Size s) {
    _lastStage = s;
    currentRemote?.policy.stage(s);
  }

  /// A tab was picked on the current session.
  void selectWindow(int id) {
    currentRemote?.selectWindow(id);
    notifyListeners();
  }

  RemoteWindow? _windowOf(RemoteSession rs) {
    for (final w in rs.windows) {
      if (w.id == rs.currentWindow) return w;
    }
    return null;
  }

  /// A session that became current gets the stage size; its policy always knows the current window.
  void _syncPolicy() {
    final rs = currentRemote;
    if (rs == null) {
      _syncedRs = null;
      return;
    }
    if (!identical(rs, _syncedRs)) {
      _syncedRs = rs;
      final s = _lastStage;
      if (s != null) rs.policy.stage(s);
    }
    // Detached, the stage is not A's window: nothing is judged until it is back (then at once).
    rs.policy.current(rs.detached ? null : _windowOf(rs));
  }

  // ---- off-stage frame rate (R6) ----
  /// The (mode, fps, density) last sent per started session, so nothing is sent twice.
  final Map<Object, (String, int, String)> _sentFps = {};

  /// Sends each started session's effective rate when it differs from the last one sent: the
  /// chosen rate on the stage or detached, 1 fps otherwise. `session.choice` is never changed.
  void _applyFps() {
    final p = port;
    if (p == null) return;
    _sentFps.removeWhere((sid, _) => !remote.containsKey(sid));
    final onStage = currentRecord;
    for (final rs in remote.values) {
      final last = _sentFps[rs.sid];
      if (last == null) continue; // not started yet: its start carries the rate
      final r = _recordOfSid(rs.sid);
      if (r == null || !_reachable(r)) continue; // a dead sid never reaches the runner (R12)
      final c = rs.choice;
      final fps = effectiveFps(c, onStage: onStage != null && identical(r, onStage), detached: rs.detached);
      final now = (c.mode, fps, c.density);
      if (now == last) continue;
      _sentFps[rs.sid] = now;
      p.setStream(rs.sid, c.mode, fps, c.density);
    }
  }

  // ---- detach (R20, R21) ----
  /// Moves the current session from the stage into native windows; the runner answers with a
  /// `DetachedEvent`. The same sid and hub session throughout: nothing is reopened.
  void detach() {
    final rs = currentRemote;
    if (rs == null || rs.detached || rs.tabs.tabs.isEmpty || currentRecord?.phase != Phase.live) return;
    port?.detach(rs.sid);
  }

  /// Puts the current session back on the stage.
  void attach() {
    final rs = currentRemote;
    if (rs == null || currentRecord?.phase != Phase.live) return;
    port?.attach(rs.sid);
  }

  /// ⌃⌘D and the stream menu's 「分离成独立窗口」/「放回主窗口」.
  void toggleDetach() {
    final rs = currentRemote;
    if (rs == null) return;
    rs.detached ? attach() : detach();
  }

  /// Whether [toggleDetach] does anything now (the menu greys its item otherwise).
  bool get canToggleDetach {
    final rs = currentRemote;
    return rs != null && currentRecord?.phase == Phase.live && (rs.detached || rs.tabs.tabs.isNotEmpty);
  }

  // ---- hub state ----
  bool get hubUsable => hub != null && hub!.alive;

  String? get hubProblem {
    if (hub == null) return hubError ?? 'rapp-hub 不可用';
    if (!hub!.alive) return 'rapp-hub 已退出 — 重启 rapp 以恢复';
    return null;
  }

  // ---- panel ----
  void togglePanel([PanelTab tab = PanelTab.sessions]) {
    panel = panel == tab ? null : tab;
    notifyListeners();
  }

  void closePanel() {
    if (panel == null) return;
    panel = null;
    notifyListeners();
  }

  // ---- sessions ----
  List<SessionGroup> get groups => groupSessions(_entries, grouping);

  int get sessionCount => _entries.length;

  SessionEntry? get current {
    for (final e in _entries) {
      if (e.key == currentKey) return e;
    }
    return null;
  }

  void setGrouping(Grouping g) {
    grouping = g;
    notifyListeners();
  }

  void select(String key) {
    currentKey = key;
    panel = null;
    notifyListeners();
  }

  void step(int delta) {
    final k = stepKey(groups, currentKey, delta);
    if (k == null) return;
    currentKey = k;
    notifyListeners();
  }

  String deviceName(String id) {
    for (final h in hub?.hosts ?? const <HubHost>[]) {
      if (h.id == id) return h.name.isEmpty ? h.id : h.name;
    }
    return id;
  }

  String appName(String id, String app) {
    return _appNames['$id/$app'] ?? app;
  }

  SessionEntry _entryOf(SessionRecord r) {
    final sid = r.sid;
    final rs = sid == null ? null : remote[sid];
    return SessionEntry(
      sid: sid,
      id: r.id,
      app: r.app,
      appName: r.appName,
      device: deviceName(r.id),
      path: r.path,
      lamp: recordLamp(r, rs),
      bytesPerSecond: r.phase == Phase.live ? rs?.bytesPerSecond : null,
      reason: r.phase == Phase.disconnected ? disconnectWord(r.reason) : null,
    );
  }

  List<SessionEntry> _mapEntries() {
    if (embeds) return [for (final r in _records.values) _entryOf(r)];
    final h = hub;
    final out = <SessionEntry>[];
    final seen = <String>{};
    if (h != null) {
      for (final s in h.sessions) {
        if (remote[s.sid]?.endReason != null || _quiet.contains(s.sid)) continue;
        final e = SessionEntry(
          sid: s.sid,
          id: s.id,
          app: s.app,
          appName: appName(s.id, s.app),
          device: deviceName(s.id),
          path: s.path,
          lamp: Lamp.active,
        );
        if (seen.add(e.key)) out.add(e);
      }
    }
    for (final e in _pending.values) {
      if (seen.add(e.key)) out.add(e);
    }
    return out;
  }

  void _onHub() {
    if (embeds) {
      _onHubEmbedded();
      return;
    }
    final old = _entries;
    final oldGroups = groups;
    _entries = _mapEntries();
    final newKeys = {for (final e in _entries) e.key};

    final h = hub!;
    if (h.alive) {
      for (final e in old) {
        if (e.sid == null || newKeys.contains(e.key)) continue;
        if (e.key == currentKey) {
          final next = stepKey(oldGroups, e.key, 1);
          currentKey = (next != null && next != e.key && newKeys.contains(next)) ? next : null;
        }
        final hubReason = h.closeReasons.remove(e.sid);
        if (_quiet.remove(e.sid)) continue;
        hint = endedHint(e.appName, hubReason);
      }
    } else if (currentKey != null && !newKeys.contains(currentKey)) {
      currentKey = null;
    }

    if (h.lastError != _lastError) {
      _lastError = h.lastError;
      if (_lastError != null) hint = hubWord(_lastError!);
    }
    notifyListeners();
  }

  /// The hub's session list changed: a live record whose sid is gone waits up to 1 s for the
  /// runner's `DisconnectedEvent` (its reason is better), then disconnects with the hub's own.
  void _onHubEmbedded() {
    final h = hub!;
    for (final r in _records.values.toList()) {
      final sid = r.sid;
      if (r.phase != Phase.live || sid == null || _hubHas(sid) || _waiting.containsKey(sid)) continue;
      final hubReason = h.closeReasons.remove(sid);
      _waiting[sid] = _Waiting(r.appName, Timer(const Duration(seconds: 1), () {
        _waiting.remove(sid);
        if (r.sid != sid || r.phase != Phase.live) return;
        _disconnect(r, hubReason ?? 'rapp-hub exited');
        notifyListeners();
      }));
    }
    // A sid nobody shows any more (ended, or closed quietly): its `closed` is not news.
    for (final sid in h.closeReasons.keys.toList()) {
      if (_recordOfSid(sid) == null) h.closeReasons.remove(sid);
    }
    _quiet.removeWhere((sid) => !_hubHas(sid));
    if (h.lastError != _lastError) {
      _lastError = h.lastError;
      if (_lastError != null) hint = hubWord(_lastError!);
    }
    notifyListeners();
  }

  void _onPortEvent(SessionEvent e) {
    final rs = remote[e.sid];
    if (rs == null) return;
    final r = _recordOfSid(e.sid);
    if (r == null) {
      // The old sid of a reconnect: only its end matters, and only to forget it.
      final holder = e is ClosedEvent ? _recordOfLastSid(e.sid) : null;
      if (holder != null) {
        holder.lastSid = null; // the runner closed it itself: nothing left to close or restore
        remote.remove(e.sid)?.dispose();
        notifyListeners();
      }
      return;
    }
    if (e is ClosedEvent) {
      if (r.phase == Phase.disconnected) return; // ended by us already, or by nobody's business
      _waiting.remove(e.sid)?.timer.cancel();
      final name = r.appName;
      _endRecord(r);
      hint = endedHint(name, e.reason);
      notifyListeners();
      return;
    }
    rs.apply(e);
    if (e is DisconnectedEvent && r.phase != Phase.disconnected) {
      _disconnect(r, e.reason);
    } else if (e is DetachedEvent) {
      // The hub logs one line per move (R10); keys typed on the stage no longer go to it.
      if (_reachable(r)) hub!.note(e.sid, e.detached ? 'detach' : 'attach', rs.tabs.tabs.length);
      if (e.detached && pictureFocused == e.sid) _blur();
    } else if (e is WindowsEvent) {
      _swapIfReady(r);
    }
    notifyListeners();
  }

  /// The link of [r] ended with [raw] (the runner's or the hub's words): the record stays, with its
  /// last frame, until the user reconnects or ends it. Callers notify.
  void _disconnect(SessionRecord r, String raw, {bool hint = false, String? hintText}) {
    if (r.lastSid != null) {
      // A reconnect that never reached the stage: its new sid goes, the old picture stays.
      final fresh = r.sid;
      if (fresh != null) {
        remote.remove(fresh)?.dispose();
        _sentFps.remove(fresh);
        _waiting.remove(fresh)?.timer.cancel();
        port?.close(fresh);
      }
      r.sid = r.lastSid;
      r.lastSid = null;
    }
    final sid = r.sid;
    final rs = sid == null ? null : remote[sid];
    r.phase = Phase.disconnected;
    r.reason = r.userDisconnect ? 'user' : raw;
    r.seq = ++_seq;
    if (rs != null) {
      r.choice = rs.choice;
      r.window = rs.currentWindow;
      rs.bytesPerSecond = 0;
      rs.linkDown(); // the runner may have said nothing (hub-first): same cleanup as its word
    }
    if (sid != null) {
      _sentFps.remove(sid);
      _waiting.remove(sid)?.timer.cancel();
      if (pictureFocused == sid) _blur();
    }
    if (hint) this.hint = hintText ?? '${r.appName} 已断开：${disconnectWord(r.reason)}';
  }

  /// Takes [r] off the list and steps to the next session if it was current. Callers set the hint.
  void _endRecord(SessionRecord r) {
    final oldGroups = groups;
    final old = r.lastSid;
    if (old != null) port?.close(old); // reconnected but not swapped yet: the old session is still open
    for (final sid in [r.sid, old]) {
      if (sid == null) continue;
      remote.remove(sid)?.dispose();
      _sentFps.remove(sid);
      _waiting.remove(sid)?.timer.cancel();
    }
    _records.remove(r.key);
    _entries = _mapEntries();
    if (currentKey == r.key) {
      final next = stepKey(oldGroups, r.key, 1);
      currentKey = (next != null && next != r.key && _records.containsKey(next)) ? next : null;
    }
  }

  /// A reconnect's first window with a picture: the new session takes the stage, the old one goes.
  void _swapIfReady(SessionRecord r) {
    final old = r.lastSid;
    final fresh = r.sid;
    if (old == null || fresh == null) return;
    final rs = remote[fresh];
    if (rs == null || !rs.windows.any((w) => w.texture != null)) return;
    port?.close(old);
    remote.remove(old)?.dispose();
    r.lastSid = null;
  }

  /// Opens (or reopens, [reconnect]) the hub session of [r] and starts the runner on it.
  Future<void> _connect(SessionRecord r, {bool reconnect = false}) async {
    final HubSession s;
    try {
      s = await hub!.open(r.id, r.app, embed: true, reconnect: reconnect);
    } catch (e) {
      if (r.ending) return;
      final missing = missingFromError('$e');
      _disconnect(r, '$e', hint: true, hintText: missing == null ? null : remoteHint(deviceName(r.id), missing));
      notifyListeners();
      return;
    }
    if (r.ending) {
      // Ended while it was connecting (R14): the session that just opened is not wanted.
      _quiet.add(s.sid);
      hub!.close(s.sid);
      return;
    }
    r.sid = s.sid;
    r.path = s.path;
    final rs = RemoteSession(s.sid, r.appName, onResize: (w, a, b) {
          if (_liveSid(s.sid)) port!.resize(s.sid, w, a, b);
        },
        onSelect: (w) {
          if (_liveSid(s.sid)) port!.selectWindow(s.sid, w);
        },
        onStream: (_) => _applyFps(),
        onDropBlock: (n) => port!.composerDropBlock(s.sid, n));
    rs.choice = r.choice;
    rs.preferWindow(r.window);
    remote[s.sid] = rs;
    r.phase = Phase.live;
    final c = r.choice;
    try {
      final p = s.port, tk = s.token;
      if (p == null || tk == null) throw 'rapp-hub 没有给出嵌入端口';
      await port!.start(StartArgs(s.sid, p, tk, c.mode, c.fps, c.density));
    } catch (e) {
      if (r.sid != s.sid) return; // it was dropped while starting: that already settled the record
      remote.remove(s.sid)?.dispose();
      _quiet.add(s.sid);
      hub!.close(s.sid);
      r.sid = null;
      _disconnect(r, '$e', hint: true);
      notifyListeners();
      return;
    }
    if (r.sid != s.sid || r.phase != Phase.live) return;
    _sentFps[s.sid] = (c.mode, c.fps, c.density);
    if (!reconnect) hint = '已打开 ${r.appName} @ ${deviceName(r.id)}';
    notifyListeners();
  }

  /// Opens the disconnected session [key] again, in the same place with the same choices.
  Future<void> reconnect(String key) async {
    final r = _records[key];
    if (r == null || r.phase != Phase.disconnected || !hubUsable) return;
    r.lastSid = r.sid;
    r.sid = null;
    r.phase = Phase.connecting;
    r.userDisconnect = false;
    r.reason = null;
    notifyListeners();
    await _connect(r, reconnect: true);
  }

  void reconnectCurrent() {
    final r = currentRecord;
    if (r != null) reconnect(r.key);
  }

  /// 「断开连接」: closes the link, keeps the session in the list.
  void disconnectCurrent() {
    final r = currentRecord;
    if (r == null || !_reachable(r)) return;
    r.userDisconnect = true;
    hub!.close(r.sid!, reason: 'user');
    notifyListeners();
  }

  Future<void> openOrSwitch(String id, String app, String appName) async {
    if (!hubUsable) return;
    final key = '$id/$app';
    if (embeds) return _openEmbedded(id, app, appName);
    for (final e in _entries) {
      if (e.key == key && e.sid != null) {
        final rs = remote[e.sid];
        if (rs != null) {
          if (rs.detached) port?.raiseDetached(e.sid!);
        } else {
          hub!.focus(e.sid!);
        }
        currentKey = key;
        panel = null;
        hint = '已切到 $appName';
        notifyListeners();
        return;
      }
    }
    if (_pending.containsKey(key)) return;
    _appNames[key] = appName;
    _pending[key] = SessionEntry(
      sid: null,
      id: id,
      app: app,
      appName: appName,
      device: deviceName(id),
      path: '',
      lamp: Lamp.connecting,
    );
    _entries = _mapEntries();
    final before = currentKey;
    currentKey = key;
    panel = null;
    notifyListeners();
    try {
      await hub!.open(id, app);
      _pending.remove(key);
      hint = '已打开 $appName @ ${deviceName(id)}';
    } catch (e) {
      _pending.remove(key);
      final missing = missingFromError('$e');
      hint = missing == null ? hubWord('$e') : remoteHint(deviceName(id), missing);
      _entries = _mapEntries();
      // Back to what was current before, if it is still open.
      if (currentKey == key) {
        currentKey = _entries.any((e) => e.key == before) ? before : null;
      }
    }
    _entries = _mapEntries();
    notifyListeners();
  }

  Future<void> _openEmbedded(String id, String app, String appName) async {
    final key = '$id/$app';
    _appNames[key] = appName;
    final r = _records[key];
    currentKey = key;
    panel = null;
    if (r == null) {
      final fresh = SessionRecord(id, app, appName, '');
      _records[key] = fresh;
      notifyListeners();
      await _connect(fresh);
    } else if (r.phase == Phase.disconnected) {
      await reconnect(key);
    } else {
      final rs = _stageRemote(r);
      if (rs != null && rs.detached) port!.raiseDetached(rs.sid);
      hint = '已切到 $appName';
      notifyListeners();
    }
  }

  /// 「切到窗口」: raises the session's own windows (a detached embedded session's, or S1's client).
  void focusCurrent() {
    if (embeds) {
      // The runner's own windows: raised with or without the hub.
      final rs = currentRemote;
      if (rs != null && rs.detached && !currentDisconnected) port!.raiseDetached(rs.sid);
      return;
    }
    final c = current;
    if (c?.sid == null) return;
    if (!hubUsable) return;
    hub!.focus(c!.sid!);
  }

  void endCurrent() {
    if (embeds) {
      _endCurrentEmbedded();
      return;
    }
    if (!hubUsable) return;
    final c = current;
    if (c?.sid == null) return;
    if (remote.containsKey(c!.sid)) {
      port!.close(c.sid!);
    } else {
      hub!.close(c.sid!);
    }
    hint = '正在结束 ${c.appName}';
    notifyListeners();
  }

  void _endCurrentEmbedded() {
    final r = currentRecord;
    if (r == null) return;
    switch (r.phase) {
      case Phase.live:
        // The runner closes the session and answers with `ClosedEvent`.
        port!.close(r.sid!);
        hint = '正在结束 ${r.appName}';
      case Phase.disconnected:
        // Nothing is running on the link; its last picture goes with the record.
        final sid = r.sid;
        if (sid != null) port!.close(sid);
        _endRecord(r);
        hint = '已结束 ${r.appName}';
      case Phase.connecting:
        // Reconnecting: the old picture goes now, the new session is closed when it opens (R14).
        final old = r.lastSid;
        if (old == null) return;
        r.ending = true;
        _endRecord(r);
        hint = '已结束 ${r.appName}';
    }
    notifyListeners();
  }

  // ---- devices ----
  Future<void> probe(String id) async {
    if (!hubUsable) return;
    probes[id] = DeviceProbe(Lamp.connecting, lampWord(Lamp.connecting),
        apps: probes[id]?.apps);
    notifyListeners();
    try {
      final apps = await hub!.apps(id);
      for (final a in apps.apps) {
        _appNames['$id/${a.app}'] = a.name;
      }
      probes[id] = DeviceProbe(Lamp.active, '在线', apps: apps);
    } catch (e) {
      probes[id] = DeviceProbe(Lamp.offline, '离线', apps: probes[id]?.apps, error: '$e');
    }
    _entries = _mapEntries();
    notifyListeners();
  }

  /// Loads the saved devices from the hub, then probes each one.
  Future<void> refreshDevices() async {
    if (!hubUsable) return;
    try {
      await hub!.refreshHosts();
    } catch (e) {
      hint = hubWord('$e');
    }
    _entries = _mapEntries();
    notifyListeners();
    probeAll();
  }

  void probeAll() {
    for (final h in hub?.hosts ?? const <HubHost>[]) {
      if (probes[h.id]?.lamp == Lamp.connecting) continue;
      probe(h.id);
    }
  }

  void selectDevice(String? id) {
    deviceTab = id;
    notifyListeners();
  }

  Future<void> removeDevice(String id) async {
    if (!hubUsable) return;
    try {
      await hub!.removeHost(id);
      probes.remove(id);
      if (deviceTab == id) deviceTab = null;
    } catch (e) {
      hint = hubWord('$e');
    }
    _entries = _mapEntries();
    notifyListeners();
  }

  int get onlineDevices => probes.values.where((p) => p.lamp == Lamp.active).length;

  // ---- prefs ----
  void setTheme(RappTheme t) {
    prefs.theme = t;
    _save();
  }

  void setStartFullscreen(bool v) {
    prefs.startFullscreen = v;
    _save();
  }

  void _save() {
    try {
      prefs.save(configDir);
    } catch (e) {
      final reason = e is FileSystemException ? (e.osError?.message ?? e.message) : "$e";
      hint = '偏好没有保存：$reason';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    hub?.removeListener(_onHub);
    _portSub?.cancel();
    for (final w in _waiting.values) {
      w.timer.cancel();
    }
    for (final r in remote.values) {
      r.dispose();
    }
    super.dispose();
  }
}

class _Waiting {
  _Waiting(this.appName, this.timer);
  final String appName;
  final Timer timer;
}

/// "stdin closed" (ended from rapp) and "quit" (its window was closed) are
/// the user's own doing; any other client exit reason is unexpected.
String endedHint(String appName, String? reason) {
  const prefix = 'rapp-client: ';
  final why = reason != null && reason.startsWith(prefix) ? reason.substring(prefix.length) : reason;
  if (why == null || why == 'stdin closed' || why == 'quit') return '已结束 $appName';
  if (why.startsWith('host says: ') && why.endsWith(' quit')) return '$appName 已结束：A 端关闭了 app';
  if (why == 'connection closed') return '$appName 意外结束：连接断了';
  if (why == 'GUI did not connect') return '$appName 意外结束：本机没有接上会话';
  return '$appName 意外结束：$why';
}
