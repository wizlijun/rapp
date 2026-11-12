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
import 'prefs.dart';
import 'session_model.dart';
import 'tokens.dart';

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
  // Hub closed first: waiting up to 1 s for the runner's reason.
  final Map<Object, _Waiting> _waiting = {};
  // Sids whose end was already reported (or never started); their hub `closed` is ignored.
  final Set<Object> _quiet = {};

  bool get embeds => port != null;

  RemoteSession? get currentRemote {
    final sid = current?.sid;
    return sid == null ? null : remote[sid];
  }

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
    if (pictureFocused == sid) return;
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
  /// The fps last sent per started session, so nothing is sent twice.
  final Map<Object, int> _sentFps = {};

  /// Sends each started session's effective rate when it differs from the last one sent: the
  /// chosen rate on the stage or detached, 1 fps otherwise. `session.choice` is never changed.
  void _applyFps() {
    final p = port;
    if (p == null) return;
    _sentFps.removeWhere((sid, _) => !remote.containsKey(sid));
    final onStage = currentRemote;
    for (final rs in remote.values) {
      final last = _sentFps[rs.sid];
      if (last == null) continue; // not started yet: its start carries the rate
      final c = rs.choice;
      final fps = effectiveFps(c, onStage: identical(rs, onStage), detached: rs.detached);
      if (fps == last) continue;
      _sentFps[rs.sid] = fps;
      p.setStream(rs.sid, c.mode, fps, c.density);
    }
  }

  // ---- detach (R20, R21) ----
  /// Moves the current session from the stage into native windows; the runner answers with a
  /// `DetachedEvent`. The same sid and hub session throughout: nothing is reopened.
  void detach() {
    final rs = currentRemote;
    if (rs == null || rs.detached || rs.tabs.tabs.isEmpty) return;
    port?.detach(rs.sid);
  }

  /// Puts the current session back on the stage.
  void attach() {
    final rs = currentRemote;
    if (rs == null) return;
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
    return rs != null && (rs.detached || rs.tabs.tabs.isNotEmpty);
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

  List<SessionEntry> _mapEntries() {
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
        final rs = remote[e.sid];
        if (rs != null) {
          // Embedded: the runner's reason wins; wait for it, at most 1 s.
          final sid = e.sid!;
          final name = e.appName;
          _waiting[sid] = _Waiting(name, Timer(const Duration(seconds: 1), () {
            _waiting.remove(sid);
            remote.remove(sid)?.dispose();
            port?.close(sid);
            hint = endedHint(name, hubReason);
            notifyListeners();
          }));
          continue;
        }
        hint = endedHint(e.appName, hubReason);
      }
      // Runner-first sessions: the hub's `closed` is now in, forget them.
      for (final sid in remote.keys.toList()) {
        if (remote[sid]!.endReason != null && !h.sessions.any((s) => s.sid == sid)) {
          h.closeReasons.remove(sid);
          remote.remove(sid)?.dispose();
        }
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

  void _onPortEvent(SessionEvent e) {
    final rs = remote[e.sid];
    if (rs == null || rs.endReason != null) return;
    if (e is! ClosedEvent) {
      rs.apply(e);
      if (e is DetachedEvent) {
        // The hub logs one line per move (R10); keys typed on the stage no longer go to it.
        hub?.note(e.sid, e.detached ? 'detach' : 'attach', rs.tabs.tabs.length);
        if (e.detached && pictureFocused == e.sid) _blur();
      }
      notifyListeners();
      return;
    }
    final w = _waiting.remove(e.sid);
    if (w != null) {
      // The hub already removed the entry; this is the reason it was waiting for.
      w.timer.cancel();
      remote.remove(e.sid)?.dispose();
      hint = endedHint(w.appName, e.reason);
      notifyListeners();
      return;
    }
    rs.apply(e);
    final oldGroups = groups;
    final name = rs.appName;
    final old = current;
    _entries = _mapEntries();
    final newKeys = {for (final x in _entries) x.key};
    if (old != null && old.sid == e.sid && old.key == currentKey) {
      final next = stepKey(oldGroups, old.key, 1);
      currentKey = (next != null && next != old.key && newKeys.contains(next)) ? next : null;
    }
    hint = endedHint(name, e.reason);
    notifyListeners();
  }

  Future<void> openOrSwitch(String id, String app, String appName) async {
    if (!hubUsable) return;
    final key = '$id/$app';
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
      final opened = await hub!.open(id, app, embed: embeds);
      if (embeds) {
        final err = await _startEmbedded(opened, appName);
        if (err != null) {
          _pending.remove(key);
          hint = err;
          if (currentKey == key) {
            _entries = _mapEntries();
            currentKey = _entries.any((e) => e.key == before) ? before : null;
          }
          _entries = _mapEntries();
          notifyListeners();
          return;
        }
      }
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

  /// Starts the runner session for an opened embedded hub session; the error hint on failure.
  Future<String?> _startEmbedded(HubSession s, String appName) async {
    final rs = RemoteSession(s.sid, appName, onResize: (w, a, b) => port!.resize(s.sid, w, a, b),
        onSelect: (w) => port!.selectWindow(s.sid, w),
        onStream: (_) => _applyFps(),
        onDropBlock: (n) => port!.composerDropBlock(s.sid, n));
    remote[s.sid] = rs;
    try {
      final p = s.port, tk = s.token;
      if (p == null || tk == null) throw 'rapp-hub 没有给出嵌入端口';
      await port!.start(StartArgs(s.sid, p, tk, 'color16', 15, 'adaptive'));
      _sentFps[s.sid] = 15;
      _applyFps();
      return null;
    } catch (e) {
      remote.remove(s.sid)?.dispose();
      _quiet.add(s.sid);
      hub!.close(s.sid);
      return hubWord('$e');
    }
  }

  /// 「切到窗口」: raises the session's own windows (a detached embedded session's, or S1's client).
  void focusCurrent() {
    final c = current;
    if (c?.sid == null) return;
    final rs = remote[c!.sid];
    if (rs != null) {
      // The runner's own windows: raised with or without the hub.
      if (rs.detached) port?.raiseDetached(c.sid!);
      return;
    }
    if (!hubUsable) return;
    hub!.focus(c.sid!);
  }

  void endCurrent() {
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

/// Hub messages the user can meet in the hint, in plain words.
const hubWords = {
  'rapp-hub exited': 'rapp-hub 已退出',
  'unknown sid': '这个会话已经结束了',
};

String hubWord(String message) => hubWords[message] ?? message;

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
