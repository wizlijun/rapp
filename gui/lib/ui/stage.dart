// The stage: where the remote window sits; a placeholder while it is elsewhere (S1, detached).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../embed/app_key_row.dart';
import '../embed/composer_editor.dart';
import '../embed/composer_panel.dart';
import '../embed/picture.dart';
import '../embed/remote_session.dart';
import '../embed/session_port.dart';
import '../term/term_key_row.dart';
import '../term/term_stage.dart';
import 'controls.dart';
import 'disconnected_stage.dart';
import 'lifecycle.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'offline_bar.dart';
import 'session_model.dart';
import 'tokens.dart';
import 'unlock.dart';

/// The password dialog for [device]; a password sent goes through [MainState.unlock].
Future<void> requestUnlock(BuildContext context, MainState state, String device) async {
  state.blurPicture();
  final request = await showUnlockDialog(context, store: state.unlockStore, device: device);
  if (request != null) {
    await state.unlock(device, request.password, remember: request.remember, auto: request.auto);
  }
}

/// The offline bar for a frozen [rec]: 停止 while a try is pending, else 重连.
Widget offlineBarFor(MainState state, SessionRecord rec) => OfflineBar(
      text: offlineWords(rec, waiting: state.waitWordOf(rec)),
      onStop: rec.retry != null ? state.stopReconnectCurrent : null,
      reconnect: rec.phase == Phase.disconnected,
      onReconnect: state.hubUsable ? state.reconnectCurrent : null,
      connecting: rec.phase != Phase.disconnected,
    );

/// The remote app picture's key row (iPad spec §8.3) is held back until the user redesigns it: it never shows,
/// whatever `app_key_row` holds. The row, its latch and the pref stay. The terminal's key row is not this one.
const showAppKeyRow = false;

/// How far the soft keyboard reaches up over the stage's bottom: the app key row and the writing panel's layer stand
/// on its top edge. The keyboard's top edge is
/// measured from the view's bottom, and out of [fullscreen] the stage stands above the home bar (MainWindow's safe
/// area), so the bar's height comes off; in fullscreen the stage reaches the view's bottom, so nothing does.
double keyboardLift(MediaQueryData mq, {required bool fullscreen}) =>
    math.max(0.0, mq.viewInsets.bottom - (fullscreen ? 0.0 : mq.viewPadding.bottom));

class Stage extends StatelessWidget {
  const Stage({super.key, required this.state, this.composerEditor, this.fullscreen = false});
  final MainState state;

  /// MainWindow's fullscreen: the stage then runs to the view's bottom edge, under the home bar.
  final bool fullscreen;
  final ComposerEditor Function()? composerEditor;

  /// The app key row's place: [keyboardLift] up off the stage's bottom. Down on the stage's bottom
  /// line it keeps off 「输入」 (12 + 48 + 8 from the right): centred while it fits between two such margins, else
  /// from the left; beside the upload strip it goes up a line. Too narrow for all twelve, it scrolls.
  Widget _appKeyRow(BuildContext context, RemoteSession rs, {required bool showsInput}) {
    final kb = keyboardLift(MediaQuery.of(context), fullscreen: fullscreen);
    final onLine = kb < 12 + 48;
    final input = showsInput && onLine && rs.composerAllowed && !rs.composer.open;
    final strip = showsInput && onLine && rs.transferStatus != null;
    const reserve = 12 + 48 + 8.0;
    return LayoutBuilder(builder: (context, c) {
      final both = c.maxWidth - 2 * reserve >= appKeyRowWidth;
      final right = input && !strip ? reserve : 0.0;
      return Padding(
        padding: EdgeInsets.only(left: both ? right : 0, right: right, bottom: strip ? kb + 12 + 48 + 8 : kb),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AppKeyRow(state: state, sid: rs.sid, latch: state.appLatch),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final theme = Theme.of(context).textTheme;
        final problem = state.hubProblem;
        final cur = state.current;
        Widget body;
        var picture = false;
        var full = false; // the body fills the stage: no padding
        var term = false; // a live terminal: the composer floats over it
        final rec = state.currentRecord;
        final rs = state.currentRemote;
        RemoteWindow? win;
        if (rs != null && rs.ready) {
          for (final w in rs.windows) {
            if (w.id == rs.currentWindow && w.hasPicture) win = w;
          }
        }
        if (problem != null) {
          body = Text(problem, textAlign: TextAlign.center);
        } else if (cur == null) {
          body = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('打开左侧面板，选一个会话或到设备里打开 app',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              RappButton.secondary(label: '打开面板', onPressed: state.togglePanel),
            ],
          );
        } else if (rec != null && rec.frozen && rs != null && !rs.detached && win != null &&
            state.termPort?.owns(rs.sid) != true) {
          // A network drop: the same Picture, frozen, under the offline bar (never input, never a resize).
          picture = true;
          body = Picture(state: state, session: rs, window: win, frozen: true,
              keyboard: keyboardLift(MediaQuery.of(context), fullscreen: fullscreen));
        } else if (rs != null && state.termPort?.owns(rs.sid) == true && ((rec?.phase == Phase.live && rec?.lastSid == null) || (rec?.frozen == true && !rs.detached && rs.windows.isNotEmpty))) {
          // A terminal (live, or frozen by a network drop): its box lines need whole device pixels.
          full = true;
          term = true;
          body = _PixelSnap(child: TermStage(
              state: state,
              session: rs,
              port: state.termPort!,
              frozen: rec?.frozen == true,
              keyboard: keyboardLift(MediaQuery.of(context), fullscreen: fullscreen),
            ));
        } else if (rec != null && (rec.phase == Phase.disconnected || rec.lastSid != null)) {
          // Dead, or reconnecting until the new picture swaps in (R10): the old frame under stripes.
          // Never input, never a resize (R25).
          full = true;
          body = DisconnectedStage(
            session: rs,
            reason: disconnectWord(rec.reason),
            reconnectWord: reconnectLabel(rec.reason),
            connecting: rec.phase != Phase.disconnected,
            onReconnect: state.hubUsable ? state.reconnectCurrent : null,
            retrying: rec.retry != null,
            waiting: state.waitWordOf(rec),
            onStop: state.stopReconnectCurrent,
            onEnd: state.endCurrent,
            sessionKey: rec.key,
          );
        } else if (rs != null && !rs.detached && win != null) {
          picture = true;
          body = Picture(state: state, session: rs, window: win,
              keyboard: keyboardLift(MediaQuery.of(context), fullscreen: fullscreen));
        } else if (!(rs != null && rs.detached) && (cur.lamp == Lamp.connecting || rs != null)) {
          body = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusLamp(cur.lamp),
              const SizedBox(width: 8),
              const Text('正在连接'),
            ],
          );
        } else {
          final word = routeWord(cur.path, forced: state.forcedRelay(cur.id));
          final path = word.isEmpty ? null : word;
          body = CustomPaint(
            foregroundPainter: _DashedBorder(t.line),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(cur.appName,
                      style: theme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    '${cur.appName} 在单独的窗口里 · ${cur.device}'
                    '${path == null ? '' : ' · $path'}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.muted),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      // A disconnected session has no window of its own to switch to.
                      if (!state.currentDisconnected)
                        RappButton.primary(
                          key: const Key('focus-button'),
                          label: '切到窗口',
                          onPressed: state.focusCurrent,
                        ),
                      if (rs != null && rs.detached)
                        RappButton.secondary(
                          key: const Key('attach-button'),
                          label: '放回主窗口',
                          onPressed: state.attach,
                        ),
                      // Keyed per session: an armed confirm never carries
                      // over to the session that becomes current next.
                      KeyedSubtree(
                        key: ValueKey('end:${cur.key}'),
                        child: ConfirmButton(
                          key: const Key('end-button'),
                          label: '结束会话',
                          onConfirmed: state.endCurrent,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }
        return LayoutBuilder(builder: (context, c) {
          // The stage's size drives A's window size (R12); overlays never change it, nor does the soft keyboard.
          state.stageSize(c.biggest);
          final keyboard = keyboardLift(MediaQuery.of(context), fullscreen: fullscreen);
          Widget stage = Container(
            key: const Key('stage'),
            alignment: Alignment.center,
            padding: picture || full ? EdgeInsets.zero : const EdgeInsets.all(16),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: t.text),
              child: body,
            ),
          );
          if (term && rs != null) {
            // The same tree whether the panel is open or not: the terminal stage is never remounted (its focus
            // would fight the panel's caret), and the lift never changes the size it lays out at (Z2). Nor does the
            // key row: it floats over the picture too.
            final keyRow = state.prefs.termKeyRow;
            final bar = rec != null && rec.frozen ? offlineBarFor(state, rec) : null;
            return Stack(
              children: [
                Positioned.fill(child: _lifted(state, rs, stage, keyRow: keyRow, narrow: c.maxWidth < keyRowWideAt)),
                if (bar != null) Positioned(top: 0, left: 0, right: 0, child: bar),
                ...composerLayer(state: state, session: rs, port: state.portOf(rs.sid)!,
                    keyRow: keyRow, keyboard: keyboard, editor: composerEditor),
              ],
            );
          }
          final port = state.port;
          final banner = state.lockBanner;
          final notice = state.hostNotice;
          final offline = rec != null && rec.frozen && picture ? offlineBarFor(state, rec) : null;
          final screens = rec != null && isDesktopApp(rec.app) && port?.supportsDetach == false
              ? state.desktopScreens(rec.id) : const [];
          return Stack(
            children: [
              stage,
              if (!full && (picture || (rs != null && rs.detached)) && rs != null && port != null)
                ...composerLayer(state: state, session: rs, port: port, keyboard: keyboard, editor: composerEditor),
              // 按键排 over an app picture (iPad spec §8.3), while the picture has the keys or the writing panel is
              // open: on the soft keyboard's top edge when it is up, floating over the stage (Z1: no resize). Not
              // where the body fills the stage, as the writing panel's layer.
              if (showAppKeyRow &&
                  !full &&
                  picture &&
                  rs != null &&
                  !rs.detached &&
                  !(rec?.frozen ?? false) &&
                  state.prefs.appKeyRow)
                Positioned.fill(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([rs, rs.composer]),
                    builder: (context, _) => state.pictureFocused == rs.sid || rs.composer.open
                        ? _appKeyRow(context, rs, showsInput: port != null)
                        : const SizedBox.shrink(),
                  ),
                ),
              if (offline != null || banner != null || notice != null || screens.length > 1)
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ?offline,
                      if (screens.length > 1)
                        Material(
                          color: Theme.of(context).colorScheme.surface,
                          child: Wrap(spacing: 8, children: [
                            for (var i = 0; i < screens.length; i++)
                              RappButton.quiet(
                                label: '屏幕 ${i + 1}',
                                onPressed: () => state.openScreen(rec!.id, screens[i].id),
                              ),
                          ]),
                        ),
                      if (banner != null)
                        Material(
                          color: const Color(0xffffe7a3),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            child: Row(children: [
                              Expanded(child: Text(banner.text, style: const TextStyle(color: Colors.black87))),
                              // Raw TextButton on purpose: it sits on the yellow banner, so its ink is fixed black.
                              TextButton(
                                style: TextButton.styleFrom(foregroundColor: Colors.black87),
                                onPressed: () => requestUnlock(context, state, rec!.id),
                                child: Text(banner.action),
                              ),
                            ]),
                          ),
                        ),
                      if (notice != null) _HostNoticeBar(state: state, notice: notice),
                    ],
                  ),
                ),
            ],
          );
        });
      },
    );
  }
}

/// A v13 host notice over the picture, in the lock banner's colours: what A did, and what to do about it.
class _HostNoticeBar extends StatelessWidget {
  const _HostNoticeBar({required this.state, required this.notice});
  final MainState state;
  final HostNotice notice;

  @override
  Widget build(BuildContext context) {
    // Raw TextButtons on purpose: they sit on the yellow banner, so their ink is fixed black.
    final style = TextButton.styleFrom(foregroundColor: Colors.black87);
    return Material(
      key: const Key('host-notice'),
      color: const Color(0xffffe7a3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(children: [
          Expanded(child: Text(notice.text, style: const TextStyle(color: Colors.black87))),
          if (notice.desktop)
            TextButton(style: style, onPressed: state.noticeDesktop, child: const Text('在桌面会话里处理')),
          if (notice.dismissable)
            TextButton(style: style, onPressed: state.noticeDismiss, child: const Text('关掉它')),
          if (notice.bundle != null)
            TextButton(style: style, onPressed: state.noticeOpen, child: const Text('打开')),
          IconButton(
            tooltip: '关闭提示',
            iconSize: 16,
            color: Colors.black54,
            onPressed: state.closeHostNotice,
            icon: const Icon(Icons.close),
          ),
        ]),
      ),
    );
  }
}

/// A terminal only (an app window's panel floats instead): while the writing panel is open the picture slides up one line (the size A sees stays as it was), in 150 ms
/// (at once without animations); Transform moves hit tests with it, so a click lands where the picture is seen.
/// A terminal's [keyRow] lifts it the same line, panel open or not; on a [narrow] stage with both, the row has a
/// line of its own above the panel and the picture goes [keyRowLift] further.
Widget _lifted(MainState state, RemoteSession session, Widget child, {bool keyRow = false, bool narrow = false}) =>
    ClipRect(
      child: ListenableBuilder(
        listenable: Listenable.merge([session, session.composer, state.composerZoom]),
        builder: (context, _) => TweenAnimationBuilder<double>(
          tween: Tween(end: _lift(session.composer.open && session.composerAllowed, keyRow, narrow, state.composerScale)),
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          builder: (_, v, child) => Transform.translate(offset: Offset(0, -v), child: child),
          child: child,
        ),
      ),
    );

/// The open panel's line grows with its zoom ([scale]); the key row alone keeps its own height.
double _lift(bool open, bool keyRow, bool narrow, double scale) =>
    (open ? pictureLift * scale : keyRow ? pictureLift : 0) + (open && keyRow && narrow ? keyRowLift : 0);

/// Paints [child] moved by under a device pixel, so its top-left lands on one: whatever it snaps in
/// its own coordinates is then snapped on the screen too, wherever the layout put it.
class _PixelSnap extends SingleChildRenderObjectWidget {
  const _PixelSnap({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPixelSnap(MediaQuery.devicePixelRatioOf(context));

  @override
  void updateRenderObject(BuildContext context, _RenderPixelSnap r) => r.dpr = MediaQuery.devicePixelRatioOf(context);
}

class _RenderPixelSnap extends RenderProxyBox {
  _RenderPixelSnap(this._dpr);

  double _dpr;
  set dpr(double v) {
    if (v == _dpr) return;
    _dpr = v;
    markNeedsPaint();
  }

  Offset _shift = Offset.zero;

  @override
  void paint(PaintingContext context, Offset offset) {
    final g = localToGlobal(Offset.zero);
    double snap(double v) => (v * _dpr).roundToDouble() / _dpr;
    _shift = Offset(snap(g.dx), snap(g.dy)) - g;
    super.paint(context, offset + _shift);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
        offset: _shift,
        position: position,
        hitTest: (result, p) => super.hitTestChildren(result, position: p),
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.translateByDouble(_shift.dx, _shift.dy, 0, 1);
}

class _DashedBorder extends CustomPainter {
  _DashedBorder(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 6.0, gap = 4.0;
    void line(Offset a, Offset b) {
      final d = b - a;
      final len = d.distance;
      final u = d / len;
      for (var x = 0.0; x < len; x += dash + gap) {
        canvas.drawLine(a + u * x, a + u * (x + dash).clamp(0, len), p);
      }
    }

    final r = Offset.zero & size;
    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(_DashedBorder o) => o.color != color;
}
