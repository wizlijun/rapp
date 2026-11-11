// The single source of UI state for the main window.
import 'dart:io';

import 'package:flutter/foundation.dart';

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
  }) {
    hub?.addListener(_onHub);
    _lastError = hub?.lastError;
    _entries = _mapEntries();
    refreshDevices();
  }

  final HubClient? hub;
  final String? hubError;
  final String configDir;
  final UiPrefs prefs;

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
    super.notifyListeners();
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
        hint = '已结束 ${e.appName}';
      }
    } else if (currentKey != null && !newKeys.contains(currentKey)) {
      currentKey = null;
    }

    if (h.lastError != _lastError) {
      _lastError = h.lastError;
      if (_lastError != null) hint = _lastError!;
    }
    notifyListeners();
  }

  Future<void> openOrSwitch(String id, String app, String appName) async {
    if (!hubUsable) return;
    final key = '$id/$app';
    for (final e in _entries) {
      if (e.key == key && e.sid != null) {
        hub!.focus(e.sid!);
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
      hint = missing == null ? '$e' : remoteHint(deviceName(id), missing);
      if (currentKey == key) currentKey = null;
    }
    _entries = _mapEntries();
    notifyListeners();
  }

  void focusCurrent() {
    if (!hubUsable) return;
    final c = current;
    if (c?.sid == null) return;
    hub!.focus(c!.sid!);
  }

  void endCurrent() {
    if (!hubUsable) return;
    final c = current;
    if (c?.sid == null) return;
    hub!.close(c!.sid!);
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
      hint = '$e';
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
      hint = '$e';
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
    super.dispose();
  }
}
