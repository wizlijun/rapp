// The stage of a session whose link is down: its last frame under stripes, with 「重连」 and 「结束会话」 (S3, R25).
// Shows only; it takes no pointer or keyboard input, and never resizes the stage.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../embed/geometry.dart';
import '../embed/picture.dart' show windowSurface;
import '../embed/remote_session.dart';
import '../embed/session_port.dart';
import 'controls.dart';
import 'lamp.dart';
import 'tokens.dart';

class DisconnectedStage extends StatefulWidget {
  const DisconnectedStage({
    super.key,
    required this.session,
    required this.reason,
    this.reconnectWord = '重连',
    required this.connecting,
    this.onReconnect,
    this.onEnd,
    this.sessionKey,
    this.hole,
  });

  /// The session whose last frame stays under the stripes; null if it never showed one.
  final RemoteSession? session;

  /// Why it disconnected, in words.
  final String reason;

  /// The button's word: 「拿回来」 after a takeover.
  final String reconnectWord;

  /// A reconnect is under way: the button gives way to 「正在连接」.
  final bool connecting;

  /// Null greys the button (no hub to reconnect through).
  final VoidCallback? onReconnect;

  /// 「结束会话」 (two taps), next to 「重连」: ends the record even if it never went live (R9).
  final VoidCallback? onEnd;

  /// Keys the end button per session: an armed confirm never carries over to the next one.
  final Object? sessionKey;

  /// Receives the last frame's global rect, so the IRON MAN grid leaves it alone (R25), like Picture's.
  final PictureHole? hole;

  @override
  State<DisconnectedStage> createState() => _DisconnectedStageState();
}

class _DisconnectedStageState extends State<DisconnectedStage> {
  final _tex = GlobalKey();

  RemoteWindow? get _window {
    final rs = widget.session;
    if (rs == null) return null;
    for (final w in rs.windows) {
      if (w.id == rs.currentWindow && w.hasPicture) return w;
    }
    return null;
  }

  void _report() {
    final h = widget.hole;
    if (h == null || !mounted) return;
    final box = _tex.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (h.owns(this, r)) return;
    h.claim(this, r);
  }

  @override
  void dispose() {
    final h = widget.hole;
    if (h != null) {
      // After the frame, so a successor that reports first is not cleared; release is by owner.
      SchedulerBinding.instance.addPostFrameCallback((_) => h.release(this));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final win = _window;
    final stripes = rowBackdrop(Lamp.disconnected, t);
    SchedulerBinding.instance.addPostFrameCallback((_) => _report());
    return ColoredBox(
      color: t.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (win != null)
            LayoutBuilder(builder: (context, c) {
              final fit = fitRect(contentSize(win), c.biggest);
              final pic = pictureRect(fit, win.visible);
              return Stack(children: [
                Positioned.fromRect(rect: pic, child: windowSurface(win, key: _tex)),
              ]);
            }),
          if (stripes != null) DecoratedBox(decoration: stripes),
          Center(
            child: widget.connecting
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const StatusLamp(Lamp.connecting),
                      const SizedBox(width: 8),
                      Text('正在连接', style: TextStyle(color: t.text)),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RappButton.accent(
                              key: const Key('reconnect-button'), label: widget.reconnectWord, onPressed: widget.onReconnect),
                          const SizedBox(width: 8),
                          KeyedSubtree(
                            key: ValueKey(('end', widget.sessionKey)),
                            child: ConfirmButton(
                                key: const Key('disconnected-end-button'), label: '结束会话', onConfirmed: widget.onEnd),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(widget.reason, key: const Key('disconnect-reason'), style: TextStyle(color: t.text)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
