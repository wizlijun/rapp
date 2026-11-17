// The main window: top bar, stage, and a side panel that overlays the stage.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/access_log_section.dart';
import '../data_relocate.dart';
import '../pages/app_profiles_section.dart';
import '../pages/ios_local_section.dart';
import '../pages/local_section.dart';
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
  });

  final MainState state;

  /// Null where there is no service (iOS): whether a relay is set then comes from the hub's `access`.
  final ServiceMonitor? monitor;
  final ServiceController? control;
  final DataRelocator? relocator;
  final FullscreenControl fullscreen;

  /// How the update buttons quit rapp (K28).
  final UpdateHooks? hooks;

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
    widget.monitor?.removeListener(_onMonitor);
    state.hub?.removeListener(_onAccess);
    _asks?.cancel();
    _sub?.cancel();
    super.dispose();
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
          relocate: widget.relocator,
          hooks: widget.hooks,
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
    // On the desktop all of it is 0.
    final pad = MediaQuery.paddingOf(context);
    final sides = EdgeInsets.only(left: pad.left, right: pad.right);
    // On macOS only ⌃⌘ chords are rapp's: ⌘[ ⌘] belong to A while the picture has focus.
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
        // Picture focused or not, ⌃⌘ chords are rapp's, so ⌃⌘D arrives here too.
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
                child: _Blur(state: state, child: TopBar(state: state, fullscreen: _full, onToggleFullscreen: _toggleFull)),
              ),
              Padding(padding: sides, child: _Blur(state: state, child: _NarrowHint(state: state))),
              Expanded(
                child: Padding(
                  padding: sides.copyWith(bottom: math.max(pad.bottom, MediaQuery.viewPaddingOf(context).bottom)),
                  child: ListenableBuilder(
                    listenable: state,
                    builder: (context, _) {
                      final open = state.panel != null;
                      return Stack(children: [
                        Positioned.fill(
                          child: _needsAccess && state.hub != null
                              ? AccessSetup(key: const Key('access-setup'), hub: state.hub!, onDone: _onAccessDone)
                              : state.overview
                                  ? Overview(state: state)
                                  : Stage(state: state),
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
