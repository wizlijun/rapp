// rapp GUI entry: the client manager, or the connection manager with `--cm`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'cm_page.dart';
import 'embed/session_port.dart';
import 'hub_client.dart';
import 'paths.dart';
import 'service_client.dart';
import 'service_control.dart';
import 'ui/fullscreen.dart';
import 'ui/main_state.dart';
import 'ui/main_window.dart';
import 'ui/prefs.dart';
import 'ui/tokens.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final env = Platform.environment;
  final os = Platform.operatingSystem;
  final cfg = configDir(env, os);
  final monitor = ServiceMonitor(readToken: tokenFileReader(cfg))..start();

  if (args.contains('--cm')) {
    await _showWindow(const Size(400, 320), 'rapp 连接管理');
    await windowManager.setPreventClose(true);
    windowManager.addListener(_QuitOnClose());
    runApp(_App(home: CmPage(monitor: monitor, onQuit: () => exit(0))));
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

  final prefs = UiPrefs.load(cfg);
  SessionPort? port;
  var doubleClick = const Duration(milliseconds: 500);
  if (Platform.isMacOS) {
    try {
      final p = ChannelSessionPort();
      doubleClick = Duration(milliseconds: await p.init());
      port = p;
    } catch (e) {
      stderr.writeln('rapp: embedded sessions unavailable: $e');
    }
  }
  final state =
      MainState(hub: hub, hubError: hubError, configDir: cfg, prefs: prefs, port: port, doubleClick: doubleClick);
  await _showWindow(const Size(1194, 834), 'rapp');
  if (prefs.startFullscreen) await WindowManagerFullscreen().setFullScreen(true);
  await windowManager.setPreventClose(true);
  final shell = _Shell(hub);
  windowManager.addListener(shell);
  trayManager.addListener(shell);
  await shell.setupTray();

  runApp(_App(
    navigatorKey: shell.navigatorKey,
    state: state,
    home: MainWindow(
      state: state,
      monitor: monitor,
      control: control,
      configDir: cfg,
      fullscreen: WindowManagerFullscreen(),
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
  const _App({required this.home, this.navigatorKey, this.state});
  final Widget home;
  final MainState? state;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    final st = state;
    if (st == null) {
      return MaterialApp(
        title: 'rapp',
        debugShowCheckedModeBanner: false,
        theme: themeDataFor(RappTheme.matrix),
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
        theme: themeDataFor(st.prefs.theme),
        themeMode: ThemeMode.dark,
        home: home,
      ),
    );
  }
}

class _QuitOnClose with WindowListener {
  @override
  void onWindowClose() => exit(0);
}

/// Close hides the window; the tray menu has 显示 / 退出.
class _Shell with WindowListener, TrayListener {
  _Shell(this.hub);
  final HubClient? hub;
  final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> setupTray() async {
    try {
      await trayManager.setIcon('assets/tray_icon.png', isTemplate: true);
      await trayManager.setToolTip('rapp');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示 rapp'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
    } catch (e) {
      stderr.writeln('rapp: tray unavailable: $e');
    }
  }

  @override
  void onWindowClose() => windowManager.hide();

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show':
        _show();
      case 'quit':
        _quit();
    }
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    final open = hub?.sessions.length ?? 0;
    if (open > 0) {
      await _show();
      final ctx = navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          title: const Text('退出 rapp？'),
          content: Text('还有 $open 个远程窗口，退出后都会断开。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('退出')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await hub?.shutdown(); // hub closes its clients on stdin EOF
    await trayManager.destroy();
    exit(0);
  }
}
