// The main window: top bar, stage, and a side panel that overlays the stage.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/access_log_section.dart';
import '../data_relocate.dart';
import '../embed/rime_glue.dart';
import '../pages/app_profiles_section.dart';
import '../pages/ios_local_section.dart';
import '../pages/global_sections.dart';
import '../pages/local_section.dart';
import '../pages/rime_settings_section.dart';
import '../hub_client.dart';
import '../ios_channel.dart';
import '../platform_caps.dart';
import '../service_client.dart';
import '../service_control.dart';
import '../update.dart';
import 'access_setup.dart';
import 'backdrop.dart';
import 'devices_tab.dart';
import 'fullscreen.dart';
import 'lamp.dart';
import 'log_model.dart';
import 'log_screen.dart';
import 'main_state.dart';
import 'overview.dart';
import 'side_panel.dart';
import 'stage.dart';
import 'shares_section.dart';
import 'tokens.dart';
import 'top_bar.dart';

/// iOS has no file manager to open a folder in: the share sheet instead.
Future<void> _openFolder(String dir) async {
  if (caps.systemOpen) return iosChannel.share(dir);
  final c = openFolderCommand(dir, Platform.operatingSystem);
  await Process.run(c.exe, c.args);
}

class MainWindow extends StatefulWidget {
  const MainWindow({
    super.key,
    required this.state,
    required this.monitor,
    required this.control,
    this.relocator,
    required this.fullscreen,
    this.hooks,
    this.rime,
  });

  final MainState state;

  /// Null where there is no service (iOS): whether a relay is set then comes from the hub's `access`.
  final ServiceMonitor? monitor;
  final ServiceController? control;
  final DataRelocator? relocator;
  final FullscreenControl fullscreen;

  /// How the update buttons quit rApp (K28).
  final UpdateHooks? hooks;

  /// The built-in input method's settings (iOS only); null elsewhere.
  final RimeGlue? rime;

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> {
  bool _full = false;
  StreamSubscription<bool>? _sub;
  StreamSubscription<String>? _asks;
  bool _asking = false;

  MainState get state => widget.state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final t = RappTokens.of(context);
    state.setNativeComposerStyle({
      'font_size': t.textSize, 'font_family': t.monoBody ? t.mono : t.font,
      'background_color': t.bg.toARGB32(), 'text_color': t.text.toARGB32(), 'hint_color': t.muted.toARGB32(), 'focus_color': t.on.toARGB32(),
    });
  }

  @override
  void initState() {
    super.initState();
    _sub = widget.fullscreen.changes.listen((v) {
      if (mounted) setState(() => _full = v);
    });
    widget.fullscreen.isFullScreen().then((v) {
      if (mounted) setState(() => _full = v);
    });
    _asks = state.unlockAsks.listen(_onAsk);
    state.addListener(_onState);
    _onState();
    widget.monitor?.addListener(_onMonitor);
    if (widget.monitor == null) {
      state.hub?.addListener(_onAccess);
      state.hub?.access().then((_) {}, onError: (_) {});
    }
    // After the first frame: a change notifies MainState's listeners, never during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onMonitor();
    });
  }

  /// Whether a relay is set lives in the service status; MainState keeps a copy for the device rows and the menu.
  void _onMonitor() {
    final m = widget.monitor;
    if (m != null) state.setRelaySet(m.status?.relaySet ?? false);
  }

  /// The hub's last `access` (no service): null until it answered.
  HubAccess? _access;

  void _onAccess() {
    final a = state.hub?.lastAccess;
    if (a == null || a == _access || !mounted) return;
    setState(() => _access = a);
    state.setRelaySet(a.hasKey);
  }

  /// 接入 worked: the overview comes back and the device list is asked again.
  void _onAccessDone(HubAccess a) {
    _onAccess();
    state.refreshDevices();
  }

  /// The in-process hub has no key yet: the access setup stands where the overview was.
  bool get _needsAccess => caps.hubInProcess && _access?.hasKey == false;

  /// A locked session wants the password: one dialog at a time.
  Future<void> _onAsk(String device) async {
    if (_asking || !mounted) return;
    _asking = true;
    try {
      await requestUnlock(context, state, device);
    } finally {
      _asking = false;
    }
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    _log?.dispose();
    _log = null;
    widget.monitor?.removeListener(_onMonitor);
    state.hub?.removeListener(_onAccess);
    _asks?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  /// One model per opening of the 日志 screen: made on the first build with `logs` on, disposed when it closes.
  LogModel? _log;

  /// Made (and opened, outside any build) when `logs` turns on; 更多 is hidden without a hub, so it is there.
  void _onState() {
    final hub = state.hub;
    if (state.logs && _log == null && hub != null) {
      _log = LogModel(fetch: (id, q) => hub.logs(id: id, query: q))..open(null);
    }
    final m = _log;
    if (state.logs || m == null) return;
    _log = null;
    // After the rebuild has dropped the screen that listens to it.
    WidgetsBinding.instance.addPostFrameCallback((_) => m.dispose());
  }

  Widget _logScreen() {
    if (_log == null) return const SizedBox.shrink();
    final hosts = state.hub?.hosts ?? const <HubHost>[];
    String label(String id) {
      final p = state.probes[id];
      final name = state.deviceName(id);
      return p == null ? name : '$name，${p.word}';
    }

    return LogScreen(
      key: const Key('log-screen'),
      model: _log!,
      devices: [for (final h in hosts) (h.id, label(h.id), state.probes[h.id]?.lamp ?? Lamp.connecting)],
      onBack: state.closeLogs,
      openFolder: _openFolder,
      logDir: widget.monitor?.status?.logDir ?? '${state.data.root}/logs',
    );
  }

  Future<void> _setFull(bool on) async {
    await widget.fullscreen.setFullScreen(on);
    if (mounted) setState(() => _full = on);
  }

  void _toggleFull() => _setFull(!_full);

  void _esc() {
    if (state.corner != null) {
      state.closeCorner();
    } else if (state.panel != null) {
      state.closePanel();
    } else if (state.logs) {
      state.closeLogs();
    } else if (state.overview) {
      state.toggleOverview();
    } else if (_full) {
      _setFull(false);
    }
  }

  Widget _local() {
    final m = widget.monitor;
    if (!caps.hasService || m == null) return _iosLocal();
    return Column(children: [
      ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) => LocalSection(
          monitor: m,
          control: widget.control,
          data: widget.state.data,
        ),
      ),
      if (caps.showsPorts)
        ListenableBuilder(
          listenable: m,
          builder: (context, _) => SharesSection(key: const ValueKey('shares-local'), api: m, online: m.running),
        ),
      ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) => AppProfilesSection(store: widget.state.profiles, openFolder: _openFolder),
      ),
      ListenableBuilder(
        listenable: m,
        builder: (context, _) => AccessLogSection(
          load: m.history,
          logDir: m.status?.logDir,
          openFolder: _openFolder,
          reload: m,
          limit: 5,
          onMore: state.hub == null ? null : state.openLogs,
        ),
      ),
    ]);
  }

  /// No service (iOS): the slim 本机, the app profiles, and an access log nothing writes to (nobody reaches an iPad).
  Widget _iosLocal() {
    final hub = state.hub;
    return Column(children: [
      if (hub != null)
        ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) =>
              IosLocalSection(hub: hub, prefs: state.prefs, onPrefs: state.savePrefs, data: state.data),
        ),
      ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) => AppProfilesSection(store: widget.state.profiles, openFolder: _openFolder),
      ),
      AccessLogSection(
        load: () async => const <Map<String, dynamic>>[],
        logDir: '${state.data.root}/logs',
        openFolder: _openFolder,
        limit: 5,
        onMore: state.hub == null ? null : state.openLogs,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final mac = Platform.isMacOS;
    // Safe areas (iPad spec §7.2): the top bar clears the status bar and the camera side; the stage clears the
    // home bar. The background (the scaffold's) still runs under them. The home bar's inset comes from the view
    // padding: with the soft keyboard up Flutter takes it out of the padding, and the stage never resizes (Z1).
    // On the desktop all of it is 0. Fullscreen (iPad/Duo) lets the stage run to every screen edge, into the
    // rounded corners and under the home bar; the top bar still clears what top inset is left.
    final pad = MediaQuery.paddingOf(context);
    final sides = EdgeInsets.only(left: pad.left, right: pad.right);
    final stagePad = _full
        ? EdgeInsets.zero
        : sides.copyWith(bottom: math.max(pad.bottom, MediaQuery.viewPaddingOf(context).bottom));
    // On macOS only ⌃⌘ chords are rApp's: ⌘[ ⌘] belong to A while the picture has focus.
    final prefixOf = mac
        ? (LogicalKeyboardKey k) => SingleActivator(k, control: true, meta: true)
        : (LogicalKeyboardKey k) => SingleActivator(k, control: true);
    return CallbackShortcuts(
      bindings: {
        mac
            ? const SingleActivator(LogicalKeyboardKey.keyF, control: true, meta: true)
            : const SingleActivator(LogicalKeyboardKey.f11): _toggleFull,
        // A held Esc leaves one thing, not the panel and then fullscreen with the key repeat.
        const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): _esc,
        // Ctrl+Enter, on every platform: the writing panel's caret (macOS keeps ⌃↩ from A too).
        const SingleActivator(LogicalKeyboardKey.enter, control: true, includeRepeats: false): state.composerKey,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true, includeRepeats: false):
            state.composerKey,
        prefixOf(LogicalKeyboardKey.bracketLeft): () => state.step(-1),
        prefixOf(LogicalKeyboardKey.bracketRight): () => state.step(1),
        // ⌃⌘O: overview; a held chord toggles once.
        if (mac)
          const SingleActivator(LogicalKeyboardKey.keyO, control: true, meta: true, includeRepeats: false):
              state.toggleOverview
        else
          const SingleActivator(LogicalKeyboardKey.keyO, control: true, includeRepeats: false):
              state.toggleOverview,
        // Picture focused or not, ⌃⌘ chords are rApp's, so ⌃⌘D arrives here too.
        // A held chord toggles once, not back and forth with the key repeat.
        if (mac)
          const SingleActivator(LogicalKeyboardKey.keyD, control: true, meta: true, includeRepeats: false):
              state.toggleDetach,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          // Z1: the soft keyboard covers the stage; the stage never resizes for it (A's windows keep their size).
          resizeToAvoidBottomInset: false,
          backgroundColor: t.bg,
          body: Backdrop(
            theme: state.prefs.theme,
            child: Column(children: [
              Padding(
                padding: sides.copyWith(top: pad.top),
                child: _Blur(state: state, child: TopBar(
                  state: state,
                  fullscreen: _full,
                  onToggleFullscreen: widget.fullscreen is NoFullscreen ? null : _toggleFull,
                )),
              ),
              Padding(padding: sides, child: _Blur(state: state, child: _NarrowHint(state: state))),
              Expanded(
                child: Padding(
                  padding: stagePad,
                  child: ListenableBuilder(
                    listenable: state,
                    builder: (context, _) {
                      final open = state.panel != null;
                      return Stack(children: [
                        Positioned.fill(
                          child: _needsAccess && state.hub != null
                              ? AccessSetup(key: const Key('access-setup'), hub: state.hub!, onDone: _onAccessDone)
                              : state.logs
                                  ? _logScreen()
                              : state.overview
                                  ? Overview(state: state, monitor: widget.monitor)
                                  : Stage(state: state, fullscreen: _full),
                        ),
                        if (open)
                          Positioned.fill(
                            child: _Blur(
                              state: state,
                              child: GestureDetector(
                                key: const Key('scrim'),
                                behavior: HitTestBehavior.opaque,
                                onTap: state.closePanel,
                                child: ColoredBox(color: t.bg.withValues(alpha: .6)),
                              ),
                            ),
                          ),
                        if (open)
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            child: _Blur(
                              state: state,
                              child: SidePanel(
                                state: state,
                                // 版本升级 and 数据目录 sit in 全局设置, not on 本机 (no service on iOS: neither; the
                                // built-in input method's 词库, 重新部署 and status instead, while its switch is on:
                                // none at all leaves no gap under the switch).
                                settings: !caps.hasService || widget.monitor == null
                                    ? (widget.rime == null || !state.prefs.rimeEnabled
                                        ? null
                                        : RimeSettingsSection(glue: widget.rime!))
                                    : ListenableBuilder(
                                        listenable: state,
                                        builder: (context, _) => GlobalSections(
                                          monitor: widget.monitor!,
                                          data: state.data,
                                          relocate: widget.relocator,
                                          hooks: widget.hooks,
                                        ),
                                      ),
                                // The shell never pops anything up for an update: just the dot (K27).
                                devicesTab: ListenableBuilder(
                                  listenable: widget.monitor ?? Listenable.merge(const []),
                                  builder: (context, _) => DevicesTab(
                                    state: state,
                                    local: _local(),
                                    localBadge: caps.onlineUpdate && updateBadge(widget.monitor?.status?.update),
                                    shares: caps.showsPorts ? widget.monitor : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ]);
                    },
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A press anywhere on [child] takes keyboard focus off the picture (R24); the press still
/// reaches [child].
class _Blur extends StatelessWidget {
  const _Blur({required this.state, required this.child});
  final MainState state;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => state.blurPicture(),
        child: child,
      );
}

/// Below 480px the top bar hides the hint; show it here instead.
class _NarrowHint extends StatelessWidget {
  const _NarrowHint({required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= 480) return const SizedBox.shrink();
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => state.hint.isEmpty
          ? const SizedBox.shrink()
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                state.hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.muted),
              ),
            ),
    );
  }
}
