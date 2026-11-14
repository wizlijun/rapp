// Top bar: panel button, prev/next, current session, hint, fullscreen.
import 'package:flutter/material.dart';

import '../embed/stream_menu.dart';
import '../pages/app_profile_page.dart';
import 'lamp.dart';
import 'lifecycle.dart';
import 'tab_chip.dart';
import 'main_state.dart';
import 'needs_you.dart';
import 'projects.dart';
import 'session_model.dart';
import 'tokens.dart';

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.state,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  /// Width the stream menu anchor (five bars + `0.0 KB/s`) takes in the row.
  static const _streamAnchorWidth = 127.0;

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
            // Embedded mode with a current session adds the stream anchor to the row
            // (full label when wide, bars only when narrow), so the thresholds that
            // keep the fixed content inside the bar move up with it.
            final embedded = state.port != null && rs != null && cur != null;
            // The fixed row: panel, prev, next, fullscreen, the needs anchor when there is a hub,
            // the overview button when shown, the stream anchor in embedded mode; and the gaps
            // (both paddings plus one after panel, overview, prev, session and next). Gaps and the
            // overview button appear only when they fit, so the row never overflows.
            // The 本机 and 远程 buttons come before it when there is room for them and a bit of the
            // session block; else the traffic label's menu carries all three parts.
            final icons = 4 + (state.hub != null ? 1 : 0);
            final trafficW = embedded ? (wide ? _streamAnchorWidth : 48.0) : 0.0;
            // Their words only in a roomy bar (the tabs and the hint need the room more).
            final words = box.maxWidth >= 1000;
            final splitW = embedded ? 2 * (words ? menuButtonWidth : 48.0) : 0.0;
            // Room for the gaps, a session block and the 已隐藏 chip besides (none of them shrink).
            final chip = rs != null && !rs.detached && rs.hidden.isNotEmpty ? 130.0 : 0.0;
            final split = embedded && box.maxWidth >= (icons + 1) * 48 + trafficW + splitW + 42 + 160 + chip;
            final streamW = trafficW + (split ? splitW : 0.0);
            double fixed(double gap, bool overview) =>
                (icons + (overview ? 1 : 0)) * 48 + streamW + (overview ? 7 : 6) * gap;
            // K11: never below 300.
            final showOverview = box.maxWidth >= 300 && box.maxWidth >= fixed(0, true);
            // Room for the gaps plus the session block's lamp (13) and its gap (8).
            final gap = box.maxWidth >= fixed(6, showOverview) + 21 ? 6.0 : 0.0;
            // The session block is a fixed-max, non-flex child so the hint's
            // Expanded takes all the slack and the fullscreen button stays at the
            // right edge. (A loose Flexible would leave its unused share of the
            // slack at the end of the row.)
            final sessionMax = (box.maxWidth - fixed(gap, showOverview)).clamp(0.0, 260.0).toDouble();
            // A detached session's windows are its tabs now; the bar shows none.
            final tabs = rs == null || rs.detached ? null : rs.tabs;
            final multi = state.sessionCount >= 2;
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
                  _icon('panel-button', Icons.menu, '面板', state.togglePanel),
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
                      child: cur == null
                          ? Text(
                              '没有选中的会话',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: t.muted),
                            )
                          : Semantics(
                              container: true,
                              excludeSemantics: true,
                              label:
                                  '${cur.appName}，${lampWord(cur.lamp)}，${_sub(cur)}',
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
                                          cur.appName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          _sub(cur),
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
                  SizedBox(width: gap),
                  _icon(
                    'next',
                    Icons.chevron_right,
                    '下一个',
                    multi ? () => state.step(1) : null,
                  ),
                  SizedBox(width: gap),
                  if (tabs != null && (tabs.tabs.length >= 2 || rs!.hidden.isNotEmpty))
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
                                    onSecondaryTap: (p) => _tabMenu(context, p, w.id),
                                    onClose: state.isMainWindow(w.id) ? null : () => state.closeWindow(w.id),
                                  ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  // Outside the scroll view: the only way back to hidden windows must never scroll away.
                  if (tabs != null && rs!.hidden.isNotEmpty)
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
                  if (embedded) ...[
                    if (split) ...[
                      _menu(context, cur, {MenuPart.session}, Corner.session, !words),
                      _menu(context, cur, {MenuPart.remote}, Corner.remote, !words),
                    ],
                    _menu(context, cur, split ? {MenuPart.stream} : allMenuParts, Corner.stream, !wide),
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
  Widget _menu(BuildContext context, SessionEntry cur, Set<MenuPart> parts, Corner corner, bool compact) {
    return StreamMenuAnchor(
      key: ValueKey((cur.sid, corner)),
      parts: parts,
      compact: compact,
      port: state.port!,
      session: state.currentRemote!,
      path: cur.path,
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
      onMarkInput: state.markInput,
      onClearInput: state.clearInputMark,
      open: state.corner == corner,
      onToggle: () => state.toggleCorner(corner),
      onClose: state.closeCorner,
      clips: state.resources.clipsOf(cur.key),
      canCopy: state.canCopy,
      canInsert: state.canInsert,
      onCopy: state.copyLocal,
      onAllClips: () => state.showPanel(PanelTab.resources),
    );
  }

  RelativeRect _at(BuildContext context, Offset p) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return RelativeRect.fromLTRB(p.dx, p.dy, overlay.size.width - p.dx, overlay.size.height - p.dy);
  }

  Future<void> _tabMenu(BuildContext context, Offset p, int window) async {
    final messenger = ScaffoldMessenger.of(context);
    final pick = await showMenu<Object?>(
      context: context,
      position: _at(context, p),
      items: [
        PopupMenuItem<Object?>(value: 'hide', enabled: !state.isMainWindow(window), child: const Text('隐藏这类窗口')),
        const PopupMenuItem<Object?>(value: 'noComposer', child: Text('这个窗口不要输入区')),
      ],
    );
    if (pick == null) return;
    final undo = pick == 'hide' ? state.hideLike(window) : state.noComposerLike(window);
    if (undo == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(pick == 'hide' ? '已隐藏，可在 app 配置里改' : '已关掉这个窗口的输入区，可在 app 配置里改'),
      action: SnackBarAction(label: '撤销', onPressed: undo),
    ));
  }

  Future<void> _hiddenMenu(BuildContext context, Offset p) async {
    final rs = state.currentRemote;
    if (rs == null) return;
    final app = state.current?.appName ?? '';
    final pick = await showMenu<(String, int)>(
      context: context,
      position: _at(context, p),
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

  String _sub(SessionEntry e) {
    final inProject = projectSubtitle(e, state.projects);
    if (inProject != null) return inProject;
    final p = pathLabels[e.path];
    if (e.lamp == Lamp.connecting || p == null) {
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
