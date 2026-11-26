// iOS entry: the hub runs in the app over dart:ffi, there is no service, tray or window manager. The data root is
// Application Support/rapp; the relay and key are typed into the app at run time (AccessSetup), never built in.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'data_dir.dart';
import 'embed/rime_glue.dart';
import 'embed/session_port.dart';
import 'embed/state_rules.dart';
import 'hub_client.dart';
import 'hub_ffi.dart';
import 'ios_channel.dart';
import 'paths.dart';
import 'platform_caps.dart' show watchHardwareKeys;
import 'term/term_session_port.dart';
import 'ui/access_setup.dart';
import 'ui/app_profile_store.dart';
import 'ui/background.dart';
import 'ui/device_os.dart';
import 'ui/fullscreen.dart';
import 'state/state_sync.dart';
import 'ui/main_state.dart';
import 'ui/main_window.dart';
import 'ui/prefs.dart';
import 'ui/system_font.dart' show fallbackTextSize;
import 'ui/tokens.dart';

void _log(String s) => stderr.writeln('rapp: $s');

Future<void> mainIos() async {
  WidgetsFlutterBinding.ensureInitialized();
  watchHardwareKeys(); // a hardware keyboard's Return sends from the writing panel (spec §8.4)
  final IosPaths paths;
  try {
    paths = await iosChannel.paths();
  } catch (e) {
    runApp(_IosApp(home: Scaffold(body: Center(child: Text('找不到数据目录：$e')))));
    return;
  }
  final root = paths.dataRoot;
  try {
    prepareDataDir(root, null);
    Directory('$root/logs').createSync(recursive: true);
  } catch (e) {
    _log('数据目录 $root: $e');
  }
  final data = DataDir(root);

  await _waitForNetwork();

  var name = '';
  try {
    name = await iosChannel.deviceName();
  } catch (_) {}
  // iPad or iPhone, for this device's own system mark on the overview.
  var idiom = '';
  try {
    idiom = await iosChannel.idiom();
  } catch (_) {}
  // No service picks this device's id here: input records and gui.json wait on it. Before the prefs are read.
  try {
    ensureDeviceId(root, name: name, os: 'ios');
  } catch (e) {
    _log('设备 id: $e');
  }
  HubClient? hub;
  String? hubError;
  try {
    hub = HubClient(FfiHubTransport.start(home: data.localDir, logDir: '$root/logs', name: name));
  } catch (e) {
    hubError = 'hub 起不来：$e';
  }

  final prefs = UiPrefs.load(data.prefsDir() ?? data.localDir);
  SessionPort? port;
  var doubleClick = const Duration(milliseconds: 500);
  try {
    final p = ChannelSessionPort();
    doubleClick = Duration(milliseconds: await p.init());
    port = p;
  } catch (e) {
    _log('embedded sessions unavailable: $e');
  }
  String? builtin;
  try {
    builtin = await rootBundle.loadString('assets/app_profiles.json');
  } catch (_) {}
  String? builtinRules;
  try {
    builtinRules = await rootBundle.loadString('assets/state_rules.json');
  } catch (_) {}
  final stateSync = StateSync(localDir: data.localDir, find: () async => stateUrlFromPorts(hub?.portMaps ?? const []))..start();
  var seenMaps = hub?.portMaps;
  // A share that appears is picked up now, not at the next 60 s look.
  hub?.addListener(() {
    if (identical(seenMaps, hub!.portMaps)) return;
    seenMaps = hub.portMaps;
    if (stateSync.status == StateStatus.none) stateSync.refresh();
  });
  final state = MainState(
      stateSync: stateSync,
      hub: hub,
      hubError: hubError,
      data: data,
      prefs: prefs,
      port: port,
      termPort: TermSessionPort(),
      doubleClick: doubleClick,
      profiles: AppProfileStore.load(data.sharedDir, builtin),
      stateRules: await StateRulesLibrary.load(data, builtinRules),
      builtinStateRules: builtinRules,
      localOs: localDeviceOs(iosIdiom: idiom),
      log: _log);
  state.overview = true;
  // The built-in input method follows 全局设置 and the session on the stage. Lives as long as the app.
  final rime = RimeGlue(state);
  // Background freezes and closes every session, coming back reconnects them; the screen stays awake while
  // a session is live (spec §9). Lives as long as the app.
  BackgroundWatch(state: state, ios: iosChannel);

  // Out of fullscreen the status bar stays and MainWindow keeps the top bar below it and the stage off the home
  // bar; in it the status bar goes and the picture fills the screen. A folded Duo is never fullscreen; unfolding
  // brings it back.
  final fullscreen = FoldFullscreen(IosFullscreen());
  try {
    await fullscreen.start(want: prefs.startFullscreen, size: _windowSize());
  } catch (e) {
    _log('全屏: $e');
  }
  WidgetsBinding.instance.addObserver(_WindowSize(() => unawaited(fullscreen.windowSize(_windowSize()))));
  runApp(_IosApp(
    state: state,
    home: MainWindow(state: state, monitor: null, control: null, fullscreen: fullscreen, rime: rime),
  ));
}

/// The app's window in logical points.
Size _windowSize() {
  final v = WidgetsBinding.instance.platformDispatcher.views.first;
  return v.physicalSize / v.devicePixelRatio;
}

/// Calls [changed] when the window changes size: folding and unfolding the Duo, rotation, Split View.
class _WindowSize with WidgetsBindingObserver {
  _WindowSize(this.changed);

  final VoidCallback changed;

  @override
  void didChangeMetrics() => changed();
}

/// China-region devices ask 无线数据 on the first request; until it is allowed nothing gets out. Shows
/// [AccessNotice] and tries again when the network changes or the app comes back from Settings.
Future<void> _waitForNetwork() async {
  Future<bool> ok() async {
    try {
      final n = await iosChannel.net();
      if (!n.ok) _log('网络检查没通过：status ${n.status} ${n.error}');
      return !n.blocked;
    } catch (_) {
      return true; // No answer from the runner: let the hub try for itself.
    }
  }

  if (await ok()) return;
  final done = Completer<void>();
  var checking = false;
  Future<void> retry() async {
    if (checking || done.isCompleted) return;
    checking = true;
    try {
      if (await ok() && !done.isCompleted) done.complete();
    } finally {
      checking = false;
    }
  }

  final sub = iosChannel.events.where((e) => e == 'pathChanged').listen((_) => retry());
  final life = AppLifecycleListener(onResume: retry);
  runApp(_IosApp(home: Scaffold(body: AccessNotice(onSettings: () => iosChannel.openSettings()))));
  await done.future;
  await sub.cancel();
  life.dispose();
}

class _IosApp extends StatelessWidget {
  const _IosApp({required this.home, this.state});
  final Widget home;
  final MainState? state;

  MaterialApp _app(RappTheme theme) => MaterialApp(
        title: 'rApp',
        debugShowCheckedModeBanner: false,
        theme: themeDataFor(theme, textSize: fallbackTextSize),
        themeMode: ThemeMode.dark,
        home: home,
      );

  @override
  Widget build(BuildContext context) {
    final st = state;
    if (st == null) return _app(RappTheme.matrix);
    return ListenableBuilder(listenable: st, builder: (context, _) => _app(st.prefs.theme));
  }
}
