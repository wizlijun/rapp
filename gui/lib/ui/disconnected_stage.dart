// The stage of a session whose link is down: its last frame under stripes, with 「重连」 and 「结束会话」 (S3, R25).
// Shows only; it takes no pointer or keyboard input, and never resizes the stage.
import 'package:flutter/material.dart';

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
    this.retrying = false,
    this.waiting,
    this.onStop,
    this.onEnd,
    this.sessionKey,
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

  /// It reconnects by itself: 「正在重连…」 and 「停止」 take the place of 「重连」.
  final bool retrying;

  /// What the automatic retry waits for (`waitWord`): shown in place of [reason], without
  /// 「正在重连…」.
  final String? waiting;

  /// 「停止」: gives up the automatic tries.
  final VoidCallback? onStop;

  /// 「结束会话」 (two taps), next to 「重连」: ends the record even if it never went live (R9).
  final VoidCallback? onEnd;

  /// Keys the end button per session: an armed confirm never carries over to the next one.
  final Object? sessionKey;

  @override
  State<DisconnectedStage> createState() => _DisconnectedStageState();
}

class _DisconnectedStageState extends State<DisconnectedStage> {
  RemoteWindow? get _window {
    final rs = widget.session;
    if (rs == null) return null;
    for (final w in rs.windows) {
      if (w.id == rs.currentWindow && w.hasPicture) return w;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final win = _window;
    final stripes = rowBackdrop(Lamp.disconnected, t);
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
                Positioned.fromRect(rect: pic, child: windowSurface(win)),
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
                      Text(widget.retrying ? '正在重连…' : '正在连接', style: TextStyle(color: t.text)),
                      if (widget.retrying) ...[
                        const SizedBox(width: 8),
                        RappButton.accent(key: const Key('stop-reconnect-button'), label: '停止', onPressed: widget.onStop),
                      ],
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.retrying)
                            RappButton.accent(key: const Key('stop-reconnect-button'), label: '停止', onPressed: widget.onStop)
                          else
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
                      Text(widget.waiting ?? widget.reason, key: const Key('disconnect-reason'), style: TextStyle(color: t.text)),
                      if (widget.retrying && widget.waiting == null) ...[
                        const SizedBox(height: 4),
                        Text('正在重连…', key: const Key('retrying-note'), style: TextStyle(color: t.text)),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
