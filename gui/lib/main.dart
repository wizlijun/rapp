// rapp GUI entry: the client manager, or the connection manager with `--cm`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'cm_page.dart';
import 'home_page.dart';
import 'hub_client.dart';
import 'paths.dart';
import 'service_client.dart';
import 'service_control.dart';

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

  await _showWindow(const Size(980, 680), 'rapp');
  await windowManager.setPreventClose(true);
  final shell = _Shell(hub);
  windowManager.addListener(shell);
  trayManager.addListener(shell);
  await shell.setupTray();

  runApp(_App(
    navigatorKey: shell.navigatorKey,
    home: HomePage(hub: hub, hubError: hubError, monitor: monitor, control: control, configDir: cfg),
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
  const _App({required this.home, this.navigatorKey});
  final Widget home;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'rapp',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: home,
      );
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
