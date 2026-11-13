// The main window: top bar, stage, and a side panel that overlays the stage.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/access_log_section.dart';
import '../data_relocate.dart';
import '../pages/app_profiles_section.dart';
import '../pages/local_section.dart';
import '../service_client.dart';
import '../service_control.dart';
import '../update.dart';
import 'backdrop.dart';
import 'devices_tab.dart';
import 'fullscreen.dart';
import 'main_state.dart';
import 'overview.dart';
import 'side_panel.dart';
import 'stage.dart';
import 'tokens.dart';
import 'top_bar.dart';

Future<void> _openFolder(String dir) async {
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
  final ServiceMonitor monitor;
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

  MainState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _sub = widget.fullscreen.changes.listen((v) {
      if (mounted) setState(() => _full = v);
    });
    widget.fullscreen.isFullScreen().then((v) {
      if (mounted) setState(() => _full = v);
    });
  }

  @override
  void dispose() {
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

  Widget _local() => Column(children: [
        ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) => LocalSection(
            monitor: widget.monitor,
            control: widget.control,
            data: widget.state.data,
            relocate: widget.relocator,
            hooks: widget.hooks,
          ),
        ),
        ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) => AppProfilesSection(store: widget.state.profiles, openFolder: _openFolder),
        ),
        ListenableBuilder(
          listenable: widget.monitor,
          builder: (context, _) => AccessLogSection(
            load: widget.monitor.history,
            logDir: widget.monitor.status?.logDir,
            openFolder: _openFolder,
            reload: widget.monitor,
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final mac = Platform.isMacOS;
    // On macOS only ⌃⌘ chords are rapp's: ⌘[ ⌘] belong to A while the picture has focus.
    final prefixOf = mac
        ? (LogicalKeyboardKey k) => SingleActivator(k, control: true, meta: true)
        : (LogicalKeyboardKey k) => SingleActivator(k, control: true);
    return CallbackShortcuts(
      bindings: {
        mac
            ? const SingleActivator(LogicalKeyboardKey.keyF, control: true, meta: true)
            : const SingleActivator(LogicalKeyboardKey.f11): _toggleFull,
        const SingleActivator(LogicalKeyboardKey.escape): _esc,
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
          backgroundColor: t.bg,
          body: Backdrop(
            theme: state.prefs.theme,
            hole: state.pictureHole,
            child: Column(children: [
              _Blur(state: state, child: TopBar(state: state, fullscreen: _full, onToggleFullscreen: _toggleFull)),
              _Blur(state: state, child: _NarrowHint(state: state)),
              Expanded(
                child: ListenableBuilder(
                  listenable: state,
                  builder: (context, _) {
                    final open = state.panel != null;
                    return Stack(children: [
                      Positioned.fill(child: state.overview ? Overview(state: state) : Stage(state: state)),
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
                                listenable: widget.monitor,
                                builder: (context, _) => DevicesTab(
                                  state: state,
                                  local: _local(),
                                  localBadge: updateBadge(widget.monitor.status?.update),
                                  screenShare: Platform.isMacOS
                                      ? (h) async => Process.run('open', ['vnc://${h.contains(':') ? '[$h]' : h}'])
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]);
                  },
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
