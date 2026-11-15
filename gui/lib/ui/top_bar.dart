// Top bar: panel button, prev/next, current session, hint, fullscreen.
import 'package:flutter/material.dart';

import '../embed/stream_menu.dart';
import '../embed/traffic_label.dart';
import '../pages/app_profile_page.dart';
import 'lamp.dart';
import 'lifecycle.dart';
import 'tab_chip.dart';
import 'main_state.dart';
import 'needs_you.dart';
import 'net_marker.dart';
import 'corner_popover.dart';
import 'projects.dart';
import 'rule_snack.dart';
import 'session_model.dart';
import 'session_switcher.dart';
import 'tokens.dart';

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.state,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  final MainState state;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 480;
        return ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final cur = state.current;
            final rs = state.currentRemote;
            // Embedded mode with a current session adds the stream anchor (the bars, 48) to the
            // row, so the thresholds that keep the fixed content inside the bar move up with it.
            final embedded = state.port != null && rs != null && cur != null;
            // A terminal: its tabs are panes (no ×, no rules), and it has no remote menu.
            final term = rs != null && state.termPort?.owns(rs.sid) == true;
            final pane = rs == null ? null : state.termPaneOf(rs);
            final title = cur == null ? '' : (pane == null ? cur.appName : '${pane.command} · ${cur.appName}');
            final cueOn = state.cue.isNotEmpty;
            final sub = cur == null ? '' : (cueOn ? state.cue : _sub(cur, pane?.title));
            // The fixed row: panel, prev, next, fullscreen, the needs anchor when there is a hub,
            // the overview button when shown, the stream anchor in embedded mode; and the gaps
            // (both paddings plus one after panel, overview, prev, session and next). Gaps and the
            // overview button appear only when they fit, so the row never overflows.
            // The 本机 button comes before it and the 远程 one before the window tabs when there is
            // room for them and a bit of the session block; else the traffic label's menu carries
            // all three parts.
            final baseIcons = 4 + (state.hub != null ? 1 : 0);
            final trafficW = embedded ? TrafficLabel.width : 0.0;
            // 上一个项目 sits beside prev/next only when the bare row still has room for it.
            final previous = state.previousProject == null
                ? null
                : state.projects.where((p) => p.id == state.previousProject).firstOrNull;
            final showPrevProject = previous != null && box.maxWidth >= (baseIcons + 1) * 48 + trafficW;
            final icons = baseIcons + (showPrevProject ? 1 : 0);
            final splitW = embedded ? (term ? 1 : 2) * 48.0 : 0.0;
            final hidden = rs != null && !rs.detached && !term && rs.hidden.isNotEmpty;
            // Room for the gaps, a session block and the 已隐藏 chip besides (none of them shrink).
            // The 「＋」 of a terminal (a chip's minimum width) goes with them.
            final plus = term && !rs.detached && state.canNewTermWindow;
            final chip = (hidden ? 130.0 : 0.0) + (plus ? 48.0 : 0.0);
            // The network marker, left of the stream anchor, while the hub has a relay to measure and
            // the bare row (no gaps, no overview button) has room for it; it goes before those do.
            const netWant = NetMarker.width;
            final net = box.maxWidth >= icons * 48 + trafficW + netWant ? state.hub?.net : null;
            final netW = net == null ? 0.0 : netWant;
            final split = embedded && box.maxWidth >= (icons + 1) * 48 + trafficW + splitW + netW + 42 + 160 + chip;
            final remoteButton = split && !term;
            final streamW = trafficW + (split ? splitW : 0.0) + netW;
            double fixed(double gap, bool overview) =>
                (icons + (overview ? 1 : 0)) * 48 +
                streamW +
                ((overview ? 7 : 6) + (showPrevProject ? 1 : 0) + (remoteButton ? 1 : 0)) * gap;
            // K11: never below 300.
            final showOverview = box.maxWidth >= 300 && box.maxWidth >= fixed(0, true);
            // Room for the gaps plus the session block's lamp (13) and its gap (8).
            final gap = box.maxWidth >= fixed(6, showOverview) + 21 ? 6.0 : 0.0;
            // The session block is a fixed-max, non-flex child so the hint's
            // Expanded takes all the slack and the fullscreen button stays at the
            // right edge. (A loose Flexible would leave its unused share of the
            // slack at the end of the row.)
            final sessionMax = (box.maxWidth - fixed(gap, showOverview) - (plus ? 48 : 0)).clamp(0.0, 260.0).toDouble();
            // A detached session's windows are its tabs now; the bar shows none.
            final tabs = rs == null || rs.detached ? null : rs.tabs;
            // With a current project, stepping stays inside it: only its open sessions count.
            final multi = state.steppableCount >= 2;
            // Any open session makes the block the session list's button; its ▾ (and padding)
            // only where it leaves the name some room.
            final canSwitch = state.sessionCount > 0;
            final arrow = canSwitch && sessionMax >= 60;
            final small = Theme.of(context).textTheme.bodySmall;
            return Container(
              height: topBarHeight,
              padding: EdgeInsets.symmetric(horizontal: gap),
              decoration: BoxDecoration(
                color: t.bg,
                border: Border(bottom: BorderSide(color: t.line)),
              ),
              child: Row(
                children: [
                  _icon('panel-button', Icons.view_sidebar_outlined, '面板', state.togglePanel),
                  SizedBox(width: gap),
                  if (showOverview) ...[
                    _overviewButton(t),
                    SizedBox(width: gap),
                  ],
                  _icon(
                    'prev',
                    Icons.chevron_left,
                    '上一个',
                    multi ? () => state.step(-1) : null,
                  ),
                  SizedBox(width: gap),
                  ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: sessionMax),
                      child: _sessionBlock(
                        t,
                        canSwitch: canSwitch,
                        arrow: arrow,
                        child: cur == null
                          ? Semantics(
                              button: canSwitch,
                              onTap: canSwitch ? _toggleSessions : null,
                              child: _noSession(t, small),
                            )
                          : Semantics(
                              container: true,
                              excludeSemantics: true,
                              button: canSwitch,
                              onTap: canSwitch ? _toggleSessions : null,
                              label:
                                  '$title，${lampWord(cur.lamp)}，$sub',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Too narrow for the lamp (13) and its gap: the name alone.
                                  if (sessionMax >= 21) ...[
                                    StatusLamp(cur.lamp),
                                    const SizedBox(width: 8),
                                  ],
                                  Flexible(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          sub,
                                          key: cueOn ? const Key('return-cue') : null,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: small?.copyWith(
                                            color: t.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                      ),
                  ),
                  SizedBox(width: gap),
                  _icon(
                    'next',
                    Icons.chevron_right,
                    '下一个',
                    multi ? () => state.step(1) : null,
                  ),
                  SizedBox(width: gap),
                  if (showPrevProject) ...[
                    Semantics(
                      container: true,
                      excludeSemantics: true,
                      button: true,
                      label: '上一个项目：${previous.name}',
                      onTap: state.backToPreviousProject,
                      child: Tooltip(
                        message: '上一个项目：${previous.name}',
                        child: IconButton(
                          key: const Key('prev-project'),
                          icon: const Icon(Icons.swap_horiz),
                          onPressed: state.backToPreviousProject,
                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        ),
                      ),
                    ),
                    SizedBox(width: gap),
                  ],
                  // The remote app's own menu, beside its window tabs.
                  if (remoteButton) ...[
                    _menu(context, cur, {MenuPart.remote}, Corner.remote),
                    SizedBox(width: gap),
                  ],
                  if (tabs != null && (tabs.tabs.length >= 2 || hidden || term))
                    Flexible(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final w in tabs.tabs)
                              Padding(
                                padding: EdgeInsets.only(right: gap),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 200),
                                  child: IntrinsicWidth(
                                    child: TabChip(
                                    label: w.title.isEmpty ? cur!.appName : w.title,
                                    selected: w.id == tabs.current,
                                    onTap: () => state.selectWindow(w.id),
                                    onSecondaryTap: term ? null : (p) => _tabMenu(context, p, w.id),
                                    onClose: term || state.isMainWindow(w.id) ? null : () => state.closeWindow(w.id),
                                  ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  // Outside the scroll view too: the tabs scroll, the 「＋」 must not scroll out of reach.
                  // It is the only tmux-changing action: asks the device for a window, on click only.
                  if (plus)
                    Tooltip(
                      message: '新开一个窗口',
                      child: TabChip(
                        key: const Key('term-new-window'),
                        label: '＋',
                        selected: false,
                        onTap: state.newTermWindow,
                      ),
                    ),
                  // Outside the scroll view: the only way back to hidden windows must never scroll away.
                  if (tabs != null && hidden)
                        Builder(
                          builder: (chipCtx) => TabChip(
                            key: const Key('hidden-tabs'),
                            label: '已隐藏 ${rs.hidden.length} 个',
                            selected: rs.hiddenFocused,
                            onTap: () {
                              final box = chipCtx.findRenderObject() as RenderBox;
                              _hiddenMenu(context, box.localToGlobal(Offset(0, box.size.height)));
                            },
                          ),
                        ),
                  if (wide)
                    Expanded(
                      child: Text(
                        state.hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.muted),
                      ),
                    )
                  else
                    const Spacer(),
                  if (state.hub != null) NeedsYouAnchor(state: state),
                  if (net != null) NetMarker(net: net, path: cur?.path),
                  if (embedded) ...[
                    if (split) _menu(context, cur, {MenuPart.session}, Corner.session),
                    _menu(context, cur, split ? {MenuPart.stream} : allMenuParts, Corner.stream),
                  ],
                  _icon(
                    'fullscreen-button',
                    fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    fullscreen ? '退出全屏' : '进入全屏',
                    onToggleFullscreen,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// One of the session's corner menus: [parts] of it, open while [corner] is.
  Widget _menu(BuildContext context, SessionEntry cur, Set<MenuPart> parts, Corner corner) {
    return StreamMenuAnchor(
      key: ValueKey((cur.sid, corner)),
      parts: parts,
      port: state.portOf(state.currentRemote!.sid)!,
      session: state.currentRemote!,
      path: cur.path,
      net: state.hub?.net,
      status: lampWord(cur.lamp),
      disconnected: state.currentDisconnected,
      reconnecting: state.currentReconnecting,
      reconnectWord: reconnectLabel(state.currentRecord?.reason),
      onDisconnect: state.hubUsable ? state.disconnectCurrent : null,
      onReconnect: state.hubUsable ? state.reconnectCurrent : null,
      onEnd: state.endCurrent,
      onToggleDetach: state.canToggleDetach ? state.toggleDetach : null,
      onRememberStream: state.rememberStream,
      onOpenProfile: () => openAppProfilePage(context, state.profiles, appId: cur.app, appName: cur.appName),
      forcedRelay: state.relaySet ? state.forcedRelay(cur.id) : null,
      onToggleRoute: state.hubUsable ? () => state.setRoute(cur.id, !state.forcedRelay(cur.id)) : null,
      onMarkInput: state.markInput,
      onClearInput: state.clearInputMark,
      termKeyRow: state.prefs.termKeyRow,
      onTermKeyRow: state.setTermKeyRow,
      open: state.corner == corner,
      onToggle: () => state.toggleCorner(corner),
      onClose: state.closeCorner,
      clips: state.resources.clipsOf(cur.key),
      canCopy: state.canCopy,
      canInsert: state.canInsert,
      onCopy: state.copyLocal,
      onAllClips: () => state.showPanel(PanelTab.resources),
      addTargets: [
        for (final p in state.projects)
          if (!p.members.any((m) => m.key == cur.key)) (p.id, p.name),
      ],
      onAddToProject: (id) => state.addMember(id, MainState.appRefOf(cur)),
      canSaveProject: state.canSaveOpenAsProject,
      onSaveProject: state.saveOpenAsProject,
    );
  }

  void _toggleSessions() => state.toggleCorner(Corner.sessions);

  /// The session block, the session list's button while there is a session to switch to.
  Widget _sessionBlock(RappTokens t, {required bool canSwitch, required bool arrow, required Widget child}) {
    if (!canSwitch) return KeyedSubtree(key: const Key('session-block'), child: child);
    final open = state.corner == Corner.sessions;
    final radius = BorderRadius.circular(t.r);
    return CornerPopover(
      open: open,
      onClose: state.closeCorner,
      scrimKey: const Key('sessions-scrim'),
      alignLeft: true,
      popover: SessionSwitcher(state: state),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('session-block'),
          onTap: _toggleSessions,
          // The block's own Semantics carries the label, the button flag and this tap.
          excludeFromSemantics: true,
          borderRadius: radius,
          child: DecoratedBox(
            decoration: open ? t.raiseBox(border: t.text) : BoxDecoration(borderRadius: radius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: arrow ? 4 : 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: child),
                    if (arrow) Icon(Icons.arrow_drop_down, size: 18, color: t.muted),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _tabMenu(BuildContext context, Offset p, int window) async {
    final messenger = ScaffoldMessenger.of(context);
    final pick = await showMenu<Object?>(
      context: context,
      position: menuAt(context, p),
      items: [
        PopupMenuItem<Object?>(value: 'hide', enabled: !state.isMainWindow(window), child: const Text('隐藏这类窗口')),
        const PopupMenuItem<Object?>(value: 'noComposer', child: Text('这个窗口不要输入区')),
      ],
    );
    if (pick == null) return;
    final undo = pick == 'hide' ? state.hideLike(window) : state.noComposerLike(window);
    if (undo == null) return;
    ruleSnack(messenger, pick == 'hide' ? '已隐藏，可在 app 配置里改' : '已关掉这个窗口的输入区，可在 app 配置里改', undo);
  }

  Future<void> _hiddenMenu(BuildContext context, Offset p) async {
    final rs = state.currentRemote;
    if (rs == null) return;
    final app = state.current?.appName ?? '';
    final pick = await showMenu<(String, int)>(
      context: context,
      position: menuAt(context, p),
      items: [
        for (final w in rs.hidden) ...[
          PopupMenuItem<(String, int)>(enabled: false, child: Text(w.title.isEmpty ? app : w.title)),
          PopupMenuItem<(String, int)>(value: ('show', w.id), child: const Text('这次显示')),
          PopupMenuItem<(String, int)>(value: ('unhide', w.id), child: const Text('不再隐藏')),
        ],
      ],
    );
    if (pick == null) return;
    if (pick.$1 == 'show') {
      state.showHiddenOnce(pick.$2);
    } else {
      state.unhide(pick.$2);
    }
  }

  /// The session's place when no session is current: the current project's name, and under it the
  /// cue while it shows (a project with nothing open still gets its cue, project spec §6.2).
  Widget _noSession(RappTokens t, TextStyle? small) {
    final project = _projectName();
    final name = Text(
      project ?? '没有选中的会话',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: t.muted),
    );
    if (project == null || state.cue.isEmpty) return name;
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        name,
        Text(
          state.cue,
          key: const Key('return-cue'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: small?.copyWith(color: t.muted),
        ),
      ],
    );
  }

  /// The current project's name, for the session's place when no session is current.
  String? _projectName() {
    final id = state.currentProject;
    return state.projects.where((p) => p.id == id).firstOrNull?.name;
  }

  /// The session's second line, and a terminal's [pane] title after it.
  String _sub(SessionEntry e, String? pane) {
    final s = _routeSub(e);
    return pane == null || pane.isEmpty ? s : '$s · $pane';
  }

  String _routeSub(SessionEntry e) {
    final inProject = projectSubtitle(e, state.projects, current: state.currentProject);
    if (inProject != null) return inProject;
    final p = routeWord(e.path, forced: state.forcedRelay(e.id));
    if (e.lamp == Lamp.connecting || p.isEmpty) {
      return e.lamp == Lamp.connecting
          ? '${e.device} · ${lampWord(e.lamp)}'
          : e.device;
    }
    return '${e.device} · $p';
  }

  Widget _overviewButton(RappTokens t) {
    final on = state.overview;
    return Semantics(
      selected: on ? true : null,
      // DecoratedBox, not Container: the border adds no padding (the row reserves exactly 48)
      // and the subtree stays the same when toggled, so keyboard focus survives.
      child: DecoratedBox(
        decoration: on ? t.raiseBox(border: t.text) : const BoxDecoration(),
        child: _icon('overview-button', Icons.grid_view, '全景', state.toggleOverview),
      ),
    );
  }

  Widget _icon(String key, IconData icon, String tip, VoidCallback? onTap) {
    return IconButton(
      key: Key(key),
      icon: Icon(icon),
      tooltip: tip,
      onPressed: onTap,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}
