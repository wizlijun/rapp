// The top bar's session list: every open session, grouped by device, a tap switches to it.
import 'package:flutter/material.dart';

import 'main_state.dart';
import 'session_model.dart';
import 'session_row.dart';

class SessionSwitcher extends StatelessWidget {
  const SessionSwitcher({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    // By device whatever the side panel groups by: the list answers "what is open where".
    final groups = groupSessions(state.entries, Grouping.device, projects: state.projects);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      children: [
        for (final g in groups) ...[
          SessionGroupTitle(g.title),
          for (final e in g.entries)
            Padding(
              key: ValueKey('switch-${e.key}'),
              padding: const EdgeInsets.only(bottom: 6),
              child: SessionRow(
                entry: e,
                forced: state.forcedRelay(e.id),
                selected: e.key == state.currentKey,
                byDevice: true,
                embedded: state.embeds,
                onTap: () {
                  state.select(e.key);
                  // Picking the current one changes no key, so nothing else closes the list.
                  state.closeCorner();
                },
              ),
            ),
        ],
      ],
    );
  }
}
