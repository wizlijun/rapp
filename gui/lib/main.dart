// rapp GUI entry: the client manager, or the connection manager with `--cm`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'cm_page.dart';
import 'embed/session_port.dart';
import 'embed/linux_session_port.dart';
import 'hub_client.dart';
import 'pages/local_section.dart';
import 'data_dir.dart';
import 'data_relocate.dart';
import 'dock_channel.dart';
import 'paths.dart';
import 'quit_gate.dart';
import 'service_client.dart';
import 'service_control.dart';
import 'term/term_session_port.dart';
import 'ui/app_profile_store.dart';
import 'ui/fullscreen.dart';
import 'tray_menu.dart';
import 'ui/main_state.dart';
import 'ui/main_window.dart';
import 'ui/prefs.dart';
import 'ui/system_font.dart';
import 'main_ios.dart';
import 'ui/tokens.dart';
import 'ui/controls.dart';

Future<void> main(List<String> args) async {
  if (Platform.isIOS) return mainIos();
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final env = Platform.environment;
  final os = Platform.operatingSystem;
  final root = dataRoot(env, os);
  try {
    prepareDataDir(root, legacyDir(env, os));
  } catch (e) {
    stderr.writeln('rapp: 数据目录 $root: $e');
  }
  final data = DataDir(root);
  final textSize = await systemTextSize();
  // The token follows the current root: `state.data` once the window exists, `data` before.
  MainState? mainState;
  final monitor = ServiceMonitor(readToken: tokenFileReader(() => (mainState?.data ?? data).localDir))..start();

  if (args.contains('--cm')) {
    await _showWindow(const Size(400, 320), 'rapp 连接管理');
    await windowManager.setPreventClose(true);
    // Linux retains this window for reuse while the main GUI is alive. Closing
    // it must not tear down an engine's GL context in the shared process.
    void closeCm() {
      if (Platform.isLinux) {
        const MethodChannel('rapp/linux').invokeMethod<void>('close_window');
      } else {
        exit(0);
      }
    }
    windowManager.addListener(_QuitOnClose(closeCm));
    runApp(_App(textSize: textSize, home: CmPage(monitor: monitor, onQuit: closeCm)));
    return;
  }

  final bin = binDir(env, Platform.resolvedExecutable);
  HubClient? hub;
  String? hubError;
  final hubExe = findBinary('rapp-hub', bin, os);
  if (hubExe == null) {
    hubError = 'rapp-hub not found in $bin（可用 RAPP_BIN_DIR 指定）';
  } else {
    try {
      hub = HubClient(await ProcessHubTransport.start(hubExe));
    } catch (e) {
      hubError = 'failed to start rapp-hub: $e';
    }
  }
  final serviceExe = findBinary('rapp-service', bin, os);
  final control = serviceExe == null ? null : ServiceController(serviceExe: serviceExe, env: env);

  final prefs = UiPrefs.load(data.prefsDir() ?? data.localDir);
  SessionPort? port;
  var doubleClick = const Duration(milliseconds: 500);
  if (Platform.isMacOS || Platform.isLinux) {
    try {
      final SessionPort p = Platform.isLinux
          ? LinuxSessionPort('$bin/rapp-session') : ChannelSessionPort();
      doubleClick = Duration(milliseconds: await p.init());
      port = p;
    } catch (e) {
      stderr.writeln('rapp: embedded sessions unavailable: $e');
    }
  }
  String? builtin;
  try {
    builtin = await rootBundle.loadString('assets/app_profiles.json');
  } catch (_) {}
  final state = MainState(
      hub: hub,
      hubError: hubError,
      data: data,
      prefs: prefs,
      port: port,
      // Terminals only beside embedded app sessions (Windows has neither yet).
      termPort: port == null ? null : TermSessionPort(),
      doubleClick: doubleClick,
      profiles: AppProfileStore.load(data.sharedDir, builtin),
      log: stderr.writeln);
  mainState = state;
  // rapp opens on the overview (全景): every device and project at a glance. Opening an app leaves it.
  state.overview = true;
  await _showWindow(const Size(1194, 834), 'rapp');
  if (prefs.startFullscreen) await WindowManagerFullscreen().setFullScreen(true);
  await windowManager.setPreventClose(true);
  final shell = _Shell(hub, port, state);
  windowManager.addListener(shell);
  trayManager.addListener(shell);
  await shell.setupTray();

  runApp(_App(
    textSize: textSize,
    navigatorKey: shell.navigatorKey,
    state: state,
    home: MainWindow(
      state: state,
      monitor: monitor,
      control: control,
      relocator: DataRelocator(
        env: env,
        os: os,
        restartService: () async =>
            control == null ? '找不到 rapp-service' : await control.run(ServiceAction.restart),
        setHubHome: (d) async => await hub?.setHome(d),
        state: state,
      ),
      fullscreen: WindowManagerFullscreen(),
      hooks: UpdateHooks(
        confirmQuit: shell._askUpgrade,
        quitNow: shell._quitNow,
      ),
    ),
  ));
}

Future<void> _showWindow(Size size, String title) => windowManager.waitUntilReadyToShow(
      WindowOptions(size: size, minimumSize: const Size(360, 260), title: title, center: true),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );

class _App extends StatelessWidget {
  const _App({required this.home, required this.textSize, this.navigatorKey, this.state});
  final Widget home;
  final double textSize;
  final MainState? state;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    final st = state;
    if (st == null) {
      return MaterialApp(
        title: 'rapp',
        debugShowCheckedModeBanner: false,
        theme: themeDataFor(RappTheme.matrix, textSize: textSize),
        themeMode: ThemeMode.dark,
        home: home,
      );
    }
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) => MaterialApp(
        title: 'rapp',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: themeDataFor(st.prefs.theme, textSize: textSize),
        themeMode: ThemeMode.dark,
        home: home,
      ),
    );
  }
}

class _QuitOnClose with WindowListener {
  _QuitOnClose(this.onClose);
  final VoidCallback onClose;
  @override
  void onWindowClose() => onClose();
}

/// Close hides the window; the tray menu has 显示 / 退出. On macOS the Dock menu lists the same
/// sessions and 常用, and ⌘Q / the Dock's 退出 ask first like the tray's 退出.
class _Shell with WindowListener, TrayListener {
  _Shell(this.hub, this.port, this.state);
  final SessionPort? port;
  final HubClient? hub;
  final MainState state;
  final navigatorKey = GlobalKey<NavigatorState>();
  String? _trayShape;
  String? _dockShape;
  bool _trayReady = false;
  DockChannel? _dock;
  /// One quit (or upgrade) confirmation on screen at a time; a second request is dropped.
  final _asking = OneAtATime();

  Future<void> setupTray() async {
    if (Platform.isMacOS) {
      _dock = DockChannel(onClick: _menuClick, onQuitRequested: _dockQuit);
    }
    try {
      await trayManager.setIcon('assets/tray_icon.png', isTemplate: true);
      // tray_manager does not implement setToolTip on Linux.
      if (!Platform.isLinux) await trayManager.setToolTip('rapp');
      _trayReady = true;
    } catch (e) {
      stderr.writeln('rapp: tray unavailable: $e');
    }
    // The Dock does not depend on the tray: a tray that failed must not leave the Dock menu out.
    if (!_trayReady && _dock == null) return;
    await _updateMenu();
    state.addListener(_updateMenu);
  }

  static String _shapeOf(List<MenuItem> items) =>
      [for (final i in items) '${i.type}|${i.key}|${i.label}|${i.disabled}'].join('\n');

  /// Both menus list the open sessions and the idle 常用 by host; each is rebuilt only when it changes.
  Future<void> _updateMenu() async {
    final favorites =
        menuFavorites(state.idleFavorites, hostName: state.deviceName, offline: state.deviceOffline);
    if (_trayReady) {
      final items = trayItems(state.entries, favorites: favorites);
      final shape = _shapeOf(items);
      if (shape != _trayShape) {
        _trayShape = shape;
        try {
          await trayManager.setContextMenu(Menu(items: items));
        } catch (e) {
          stderr.writeln('rapp: tray menu: $e');
        }
      }
    }
    final dock = _dock;
    if (dock != null) {
      final items = dockItems(state.entries, favorites: favorites);
      final shape = _shapeOf(items);
      if (shape != _dockShape) {
        _dockShape = shape;
        try {
          await dock.setMenu(items);
        } catch (e) {
          stderr.writeln('rapp: dock menu: $e');
        }
      }
    }
  }

  /// A tray or Dock item. A session item raises a detached session's own window, or shows the
  /// main window on it; a 常用 item opens that app (or switches to it). Stale keys do nothing.
  void _menuClick(String? key) {
    switch (key) {
      case 'show':
        _show();
        return;
      case 'quit':
        _quit();
        return;
    }
    final session = sessionKeyOf(key);
    if (session != null) {
      if (!state.entries.any((e) => e.key == session)) return;
      if (state.raiseIfDetached(session)) return;
      _show();
      state.select(session);
      return;
    }
    final fav = favKeyOf(key);
    if (fav != null) {
      final f = state.favorites.where((a) => a.key == fav).firstOrNull;
      if (f == null) return;
      _show();
      state.openOrSwitch(f.device, f.bundle, f.name);
    }
  }

  /// ⌘Q or the Dock's 退出: asks like the tray's 退出, then lets the native side terminate.
  Future<void> _dockQuit() async {
    if (await _askQuit()) await _dock?.confirmQuit();
  }

  @override
  void onWindowClose() {
    if (Platform.isLinux) {
      // Flutter can deliver platform calls while GTK waits for a resized frame.
      // Let the native GTK loop finish that draw before unmapping the window.
      const MethodChannel('rapp/linux').invokeMethod<void>('hide_window');
    } else {
      windowManager.hide();
    }
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) => _menuClick(item.key);

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  int get openWindows => hub?.sessions.length ?? 0;

  Future<void> _quit() async {
    if (await _askQuit()) await _quitNow();
  }

  /// The quit confirmation, shown once at a time: false for a request while one is already up.
  Future<bool> _askQuit() => _asking.ask(() => _confirmQuit(
        title: '退出 rapp？',
        body: '还有 $openWindows 个远程窗口，退出后都会断开。',
        ok: '退出',
      ));

  /// The upgrade's confirmation, behind the same gate as quitting.
  Future<bool> _askUpgrade() => _asking.ask(() => _confirmQuit(
        title: '升级 rapp？',
        body: '还有 $openWindows 个远程窗口，升级时会断开。',
        ok: '升级',
      ));

  /// True straight away when no remote window is open; otherwise asks.
  Future<bool> _confirmQuit({required String title, required String body, required String ok}) async {
    if (openWindows == 0) return true;
    await _show();
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    final yes = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          RappButton.quiet(label: '取消', onPressed: () => Navigator.pop(c, false)),
          RappButton.primary(label: ok, onPressed: () => Navigator.pop(c, true)),
        ],
      ),
    );
    return yes == true;
  }

  Future<void> _quitNow() async {
    port?.dispose();
    state.termPort?.dispose();
    await hub?.shutdown(); // hub closes its clients on stdin EOF
    await trayManager.destroy();
    exit(0);
  }
}
