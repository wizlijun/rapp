// Sessions tab of the side panel: grouping switch and the session cards the overview uses.
import 'package:flutter/material.dart';

import 'main_state.dart';
import 'session_block.dart';
import 'session_model.dart';
import 'session_row.dart' show SessionGroupTitle;
import 'tab_chip.dart';
import 'term_restore_dialog.dart' show showTermRestore;
import 'tokens.dart';

class SessionsTab extends StatelessWidget {
  const SessionsTab({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final groups = state.groups;
        final idle = state.idleFavorites;
        final elsewhere = state.elsewhereEntries;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
              child: Row(
                children: [
                  for (final g in Grouping.values) ...[
                    if (g != Grouping.values.first) const SizedBox(width: 6),
                    Expanded(
                      child: TabChip(
                        key: Key('group-${g.name}'),
                        label: groupingLabel(g),
                        selected: state.grouping == g,
                        onTap: () => state.setGrouping(g),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                children: [
                  if (groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(2),
                      child: Text(
                        '没有打开的会话。到「设备」里打开一个 app。',
                        style: TextStyle(color: t.muted),
                      ),
                    ),
                  for (final g in groups) ...[
                    g.projectId == null
                        ? SessionGroupTitle(g.title)
                        : SessionGroupTitle(g.title, key: Key('group-${g.projectId}'), onTap: () => state.switchProject(g.projectId!)),
                    for (final e in g.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SessionBlock(
                          state: state,
                          entry: e,
                          keyPrefix: 'session',
                          showDevice: state.grouping != Grouping.device,
                        ),
                      ),
                  ],
                  if (elsewhere.isNotEmpty) ...[
                    const SessionGroupTitle('别处开着', key: Key('group-elsewhere')),
                    for (final e in elsewhere)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SessionBlock(state: state, entry: e, keyPrefix: 'elsewhere'),
                      ),
                  ],
                  if (idle.isNotEmpty) ...[
                    const SessionGroupTitle('常用', key: Key('group-favorites')),
                    for (final f in idle)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: FavoriteBlock(
                          favorite: f,
                          label: state.labelOf(f),
                          verb: state.favoriteVerb(f),
                          keyPrefix: 'favorite',
                          device: state.deviceName(f.device),
                          onTap: state.hubUsable
                              ? () => state.favoriteVerb(f) == '恢复'
                                  ? showTermRestore(context, state, f.device)
                                  : state.openFavorite(f)
                              : null,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
