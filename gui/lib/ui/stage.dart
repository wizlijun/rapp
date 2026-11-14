// The stage: where the remote window sits; a placeholder while it is elsewhere (S1, detached).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../embed/composer_panel.dart';
import '../embed/picture.dart';
import '../embed/session_port.dart';
import '../hub_client.dart';
import '../term/term_stage.dart';
import 'controls.dart';
import 'disconnected_stage.dart';
import 'lifecycle.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'session_model.dart';
import 'tokens.dart';

class Stage extends StatelessWidget {
  const Stage({super.key, required this.state});
  final MainState state;

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
        } else if (rs != null && state.termPort?.owns(rs.sid) == true && rec?.phase == Phase.live && rec?.lastSid == null) {
          // A terminal: no composer over it yet (G2); its box lines need whole device pixels.
          full = true;
          body = _PixelSnap(child: TermStage(
              state: state,
              session: rs,
              port: state.termPort!,
              attached: [
                for (final r in state.hub?.termLists[rec?.id]?.terms ?? const <TermRow>[])
                  if (r.id == rec?.app) r.attached
              ].firstOrNull,
            ));
        } else if (rs != null && !rs.detached && win != null) {
          picture = true;
          body = Picture(state: state, session: rs, window: win);
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
          // The stage's size drives A's window size (R12); overlays never change it.
          state.stageSize(c.biggest);
          Widget stage = Container(
            key: const Key('stage'),
            alignment: Alignment.center,
            padding: picture || full ? EdgeInsets.zero : const EdgeInsets.all(16),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: t.text),
              child: body,
            ),
          );
          // While the writing panel is open the picture slides up one line (the size A sees stays as it was);
          // Transform moves hit tests with it, so a click lands where the picture is seen.
          if (picture && rs != null) {
            final session = rs;
            final inner = stage;
            stage = ClipRect(
              child: ListenableBuilder(
                listenable: Listenable.merge([session, session.composer]),
                builder: (context, _) => TweenAnimationBuilder<double>(
                  tween: Tween(end: session.composer.open && session.composerAllowed ? pictureLift : 0),
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  builder: (_, v, child) => Transform.translate(offset: Offset(0, -v), child: child),
                  child: inner,
                ),
              ),
            );
          }
          final port = state.port;
          // A detached session keeps its 「输入」 here: the placeholder stands for its windows.
          if (full || !(picture || (rs != null && rs.detached)) || rs == null || port == null) return stage;
          // The composer floats over the picture's bottom edge; opening it never resizes A.
          return Stack(
            children: [
              stage,
              ...composerLayer(state: state, session: rs, port: port),
            ],
          );
        });
      },
    );
  }
}

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
