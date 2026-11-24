// Top bar, left to right: panel, overview, the project menu (with two projects or more), prev, the session (its list), next, the window menu,
// the remote app's menu; then the hint, right-aligned (its ▾ opens the history); then 需要你, the
// network marker, the traffic label (the stream menu), the session menu, fullscreen (where there is a fullscreen control).
// Narrowing, it yields in this order (iPad spec §7.2): the hint's line (its ▾ stays), the 本机 button, the network
// marker, the window title (the count stays).
import 'package:flutter/material.dart';

import '../embed/stream_menu.dart';
import '../embed/traffic_label.dart';
import '../pages/app_profile_page.dart';
import 'lamp.dart';
import 'lifecycle.dart';
import 'main_state.dart';
import 'project_menu.dart';
import 'needs_you.dart';
import 'window_menu.dart';
import 'net_marker.dart';
import 'corner_popover.dart';
import 'hint_history.dart';
import 'projects.dart';
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

  /// Null where there is nothing to make fullscreen: no button then.
  final VoidCallback? onToggleFullscreen;

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
            final title = cur?.title ?? '';
            final cueOn = state.cue.isNotEmpty;
            final sub = cur == null ? '' : (cueOn ? state.cue : _routeSub(cur));
            // The fixed row: panel, prev, next, fullscreen, the needs anchor when there is a hub,
            // the overview button when shown, the stream anchor in embedded mode; and the gaps
            // (both paddings plus one after panel, overview, prev, session and next). Gaps and the
            // overview button appear only when they fit, so the row never overflows.
            // The 本机 button comes before it and the 远程 one before the window tabs when there is
            // room for them and a bit of the session block; else the traffic label's menu carries
            // all three parts.
            final toggleFullscreen = onToggleFullscreen;
            final fullscreenButton = toggleFullscreen != null;
            final baseIcons = (fullscreenButton ? 4 : 3) + (state.hub != null ? 1 : 0);
            final trafficW = embedded ? TrafficLabel.width : 0.0;
            // The project menu leads the session group while there are projects to switch
            // between and the bare row has room for its icon; it names the project further down.
            final showProject = ProjectMenu.shows(state) && box.maxWidth >= (baseIcons + 1) * 48 + trafficW;
            final icons = baseIcons + (showProject ? 1 : 0);
            final splitW = embedded ? (term ? 1 : 2) * 48.0 : 0.0;
            // The network marker, left of the stream anchor, while the hub has a relay to measure and
            // the bare row (no gaps, no overview button) has room for it; it goes before those do. With a window
            // control to show it also leaves that its title: the marker goes first.
            const netWant = NetMarker.width;
            final wmWants = rs != null && !rs.detached && WindowMenu.shows(state, term: term);
            // The window title wants room for itself, the overview button, the gaps (eight of 6) and a bit of the
            // session block (60), so the session block is never squeezed under a tap target (iPad spec §7.2).
            const wmFullRoom = WindowMenu.fullWidth + 48 + 8 * 6 + 60;
            final net = box.maxWidth >= icons * 48 + trafficW + netWant + (wmWants ? wmFullRoom : 0)
                ? state.hub?.net
                : null;
            final netW = net == null ? 0.0 : netWant;
            // The window control: one button, never a row that grows. What the bare row leaves it,
            // beside a bit of the session block, decides whether it carries a title or shrinks to
            // the icon and the count. Hidden windows keep it on screen at any width: the menu is
            // the only way back to them.
            final wmRoom = box.maxWidth - (icons * 48 + trafficW + netW);
            final wmHidden = rs != null && !rs.detached && WindowMenu.hiddenOf(state, term: term).isNotEmpty;
            final wmShow = wmWants && (wmHidden || wmRoom >= WindowMenu.compactWidth + 60);
            final wmFull = wmShow && wmRoom >= wmFullRoom;
            final wmW = !wmShow ? 0.0 : (wmFull ? WindowMenu.fullWidth : WindowMenu.compactWidth);
            final split = embedded && box.maxWidth >= (icons + 1) * 48 + trafficW + splitW + netW + 42 + 160 + wmW;
            final remoteButton = split && !term;
            final streamW = trafficW + (split ? splitW : 0.0) + netW;
            // The project's name once everything else, the gaps and a fair session block fit.
            final pmFull = showProject &&
                box.maxWidth - (icons * 48 + streamW + wmW + 9 * 6) >= ProjectMenu.fullWidth - 48 + 200;
            final pmExtra = pmFull ? ProjectMenu.fullWidth - 48 : 0.0;
            double fixed(double gap, bool overview) =>
                (icons + (overview ? 1 : 0)) * 48 +
                streamW +
                wmW +
                pmExtra +
                ((overview ? 7 : 6) + (showProject ? 1 : 0) + (remoteButton ? 1 : 0) + (wmShow ? 1 : 0)) * gap;
            // K11: never below 300.
            final showOverview = box.maxWidth >= 300 && box.maxWidth >= fixed(0, true);
            // Room for the gaps plus the session block's lamp (13) and its gap (8).
            final gap = box.maxWidth >= fixed(6, showOverview) + 21 ? 6.0 : 0.0;
            // The session block is a fixed-max, non-flex child so the hint's
            // Expanded takes all the slack and the fullscreen button stays at the
            // right edge. (A loose Flexible would leave its unused share of the
            // slack at the end of the row.)
            final sessionMax = (box.maxWidth - fixed(gap, showOverview)).clamp(0.0, 260.0).toDouble();
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
                  // The project menu, ahead of the session list: it narrows what the list holds.
                  if (showProject) ...[
                    ProjectMenu(state: state, compact: !pmFull),
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
                  // One button for every window, hidden ones included: the title, and a menu to
                  // switch. It is not flexible, so it can never push the rest of the row out.
                  if (wmShow) ...[
                    WindowMenu(state: state, term: term, compact: !wmFull),
                    SizedBox(width: gap),
                  ],
                  // The remote app's own menu, after its window tabs.
                  if (remoteButton) ...[
                    _menu(context, cur, {MenuPart.remote}, Corner.remote),
                    SizedBox(width: gap),
                  ],
                  // The hint, right-aligned against the right-hand group, with its history's ▾.
                  // Its line goes first: never while 本机 has had to fold into the traffic menu.
                  Expanded(child: HintAnchor(state: state, showText: wide && (split || !embedded))),
                  if (state.hub != null) NeedsYouAnchor(state: state),
                  if (net != null) NetMarker(net: net, path: cur?.path),
                  if (embedded) ...[
                    _menu(context, cur, split ? {MenuPart.stream} : allMenuParts, Corner.stream),
                    if (split) _menu(context, cur, {MenuPart.session}, Corner.session),
                  ],
                  if (fullscreenButton)
                    _icon(
                      'fullscreen-button',
                      fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      fullscreen ? '退出全屏' : '进入全屏',
                      toggleFullscreen,
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
      termFit: state.prefs.termFit,
      onTermFit: state.setTermFit,
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

  /// Every icon in the bar is drawn at this size (the network and traffic marks match its ink).
  static const iconSize = 20.0;

  Widget _icon(String key, IconData icon, String tip, VoidCallback? onTap) {
    return IconButton(
      key: Key(key),
      icon: Icon(icon, size: iconSize),
      tooltip: tip,
      onPressed: onTap,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}
