// The gray line at the bottom of 按键 and 常用语: whether the 快捷区 settings follow a center service (quick-row spec §10.5).
import 'package:flutter/material.dart';

import '../quick/quick_sync.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';

class QuickSyncLine extends StatelessWidget {
  const QuickSyncLine({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final sync = state.quickSync;
    if (sync == null) return _line(t, _text(null));
    return ListenableBuilder(listenable: sync, builder: (_, _) => _line(t, _text(sync)));
  }

  Widget _line(RappTokens t, String text) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(text, key: const Key('quick-sync-line'), style: TextStyle(color: t.muted, fontSize: t.textSize - 2)),
      );

  String _text(QuickSync? s) {
    switch (s?.status ?? QuickSyncStatus.local) {
      case QuickSyncStatus.local:
        return '只存在本机（没有中心服务）';
      case QuickSyncStatus.synced:
        final id = s!.hostId;
        return id == null ? '已和中心服务同步' : '已和 ${state.deviceName(id)} 上的中心服务同步';
      case QuickSyncStatus.waiting:
        return '连不上中心服务，改动会在连上后同步';
    }
  }
}
