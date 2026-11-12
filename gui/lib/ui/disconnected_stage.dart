// The stage of a session whose link is down: its last frame under stripes, with 「重连」 (S3, R25).
// Shows only; it takes no pointer or keyboard input, and never resizes the stage.
import 'package:flutter/material.dart';

import '../embed/geometry.dart';
import '../embed/remote_session.dart';
import '../embed/session_port.dart';
import 'controls.dart';
import 'lamp.dart';
import 'tokens.dart';

class DisconnectedStage extends StatelessWidget {
  const DisconnectedStage({
    super.key,
    required this.session,
    required this.reason,
    required this.connecting,
    this.onReconnect,
  });

  /// The session whose last frame stays under the stripes; null if it never showed one.
  final RemoteSession? session;

  /// Why it disconnected, in words.
  final String reason;

  /// A reconnect is under way: the button gives way to 「正在连接」.
  final bool connecting;

  /// Null greys the button (no hub to reconnect through).
  final VoidCallback? onReconnect;

  RemoteWindow? get _window {
    final rs = session;
    if (rs == null) return null;
    for (final w in rs.windows) {
      if (w.id == rs.currentWindow && w.texture != null) return w;
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
                Positioned.fromRect(rect: pic, child: Texture(textureId: win.texture!)),
              ]);
            }),
          if (stripes != null) DecoratedBox(decoration: stripes),
          Center(
            child: connecting
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
                      RappButton.accent(key: const Key('reconnect-button'), label: '重连', onPressed: onReconnect),
                      const SizedBox(height: 12),
                      Text(reason, key: const Key('disconnect-reason'), style: TextStyle(color: t.text)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
