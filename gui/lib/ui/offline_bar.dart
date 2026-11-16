// The thin bar over a frozen stage: why the link is down, and 停止 / 重连 (offline-freeze spec).
import 'package:flutter/material.dart';

import 'controls.dart';
import 'lamp.dart';
import 'tokens.dart';

class OfflineBar extends StatelessWidget {
  const OfflineBar({
    super.key,
    required this.text,
    this.onStop,
    this.onReconnect,
    this.reconnect = false,
    this.connecting = false,
  });

  final String text;

  /// Set while an automatic try is pending: shows 「停止」.
  final VoidCallback? onStop;

  /// Else, with [reconnect]: 「重连」, greyed while this is null.
  final VoidCallback? onReconnect;
  final bool reconnect;

  /// Coming back right now: the connecting lamp instead of the disconnected one.
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Container(
      key: const Key('offline-bar'),
      decoration: t.floatBox(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(children: [
        StatusLamp(connecting ? Lamp.connecting : Lamp.disconnected),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              key: const Key('offline-text'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.text)),
        ),
        if (onStop != null) ...[
          const SizedBox(width: 8),
          RappButton.secondary(
              key: const Key('stop-reconnect-button'), label: '停止', onPressed: onStop, onPicture: true, oneLine: true),
        ] else if (reconnect) ...[
          const SizedBox(width: 8),
          RappButton.secondary(
              key: const Key('reconnect-button'), label: '重连', onPressed: onReconnect, onPicture: true, oneLine: true),
        ],
      ]),
    );
  }
}
