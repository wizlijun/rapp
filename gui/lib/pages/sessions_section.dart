// 会话: windows this machine has open on remote hosts.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../ui/session_model.dart';
import 'section_card.dart';

class SessionsSection extends StatelessWidget {
  const SessionsSection({super.key, required this.hub});
  final HubClient hub;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final names = {for (final h in hub.hosts) h.id: h.name};
        final sessions = hub.sessions;
        return SectionCard(title: '会话', children: [
          if (sessions.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('没有打开的窗口')),
          for (final s in sessions)
            ListTile(
              key: Key('session-${s.sid}'),
              dense: true,
              leading: const Icon(Icons.web_asset),
              title: Text(s.app),
              subtitle: Text('${names[s.id]?.isNotEmpty == true ? names[s.id] : s.id} · ${pathLabels[s.path] ?? s.path}'),
              trailing: IconButton(tooltip: '关闭', icon: const Icon(Icons.close), onPressed: () => hub.close(s.sid)),
            ),
        ]);
      },
    );
  }
}
