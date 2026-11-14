// The stage: where the remote window sits; a placeholder while it is elsewhere (S1, detached).
import 'package:flutter/material.dart';

import '../embed/composer_bar.dart';
import '../embed/picture.dart';
import '../embed/session_port.dart';
import 'controls.dart';
import 'disconnected_stage.dart';
import 'lifecycle.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'session_model.dart';
import 'tokens.dart';
import 'unlock.dart';

class Stage extends StatelessWidget {
  const Stage({super.key, required this.state});
  final MainState state;

  Future<void> _requestUnlock(BuildContext context, String device) async {
    state.blurPicture();
    final request = await showUnlockDialog(context, store: state.unlockStore, device: device);
    if (request != null) {
      await state.unlock(device, request.password, remember: request.remember, auto: request.auto);
    }
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
            onStop: state.stopReconnectCurrent,
            onEnd: state.endCurrent,
            sessionKey: rec.key,
          );
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
          final stage = Container(
            key: const Key('stage'),
            alignment: Alignment.center,
            padding: picture || full ? EdgeInsets.zero : const EdgeInsets.all(16),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: t.text),
              child: body,
            ),
          );
          final port = state.port;
          final banner = state.lockBanner;
          final screens = rec != null && isDesktopApp(rec.app) && port?.supportsDetach == false
              ? state.desktopScreens(rec.id) : const [];
          return Stack(
            children: [
              stage,
              if (!full && (picture || (rs != null && rs.detached)) && rs != null && port != null)
                ...composerLayer(state: state, session: rs, port: port),
              if (banner != null || screens.length > 1)
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (screens.length > 1)
                        Material(
                          color: Theme.of(context).colorScheme.surface,
                          child: Wrap(spacing: 8, children: [
                            for (var i = 0; i < screens.length; i++)
                              TextButton(
                                onPressed: () => state.openScreen(rec!.id, screens[i].id),
                                child: Text('屏幕 ${i + 1}'),
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
                              TextButton(
                                onPressed: isDesktopApp(rec!.app)
                                    ? () => _requestUnlock(context, rec.id)
                                    : () => state.openOrSwitch(rec.id, 'desktop:', '桌面'),
                                child: Text(banner.action),
                              ),
                            ]),
                          ),
                        ),
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
