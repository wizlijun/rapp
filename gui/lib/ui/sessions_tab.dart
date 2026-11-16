// Sessions tab of the side panel: grouping switch and 60px session rows.
import 'package:flutter/material.dart';

import 'controls.dart' show DashedOutline;
import 'lamp.dart';
import 'main_state.dart';
import 'session_model.dart';
import 'session_row.dart';
import 'tab_chip.dart';
import 'workspace_store.dart';
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
                        child: SessionRow(
                          entry: e,
                          forced: state.forcedRelay(e.id),
                          selected: e.key == state.currentKey,
                          byDevice: state.grouping == Grouping.device,
                          embedded: state.embeds,
                          onTap: () => state.select(e.key),
                        ),
                      ),
                  ],
                  if (idle.isNotEmpty) ...[
                    const SessionGroupTitle('常用', key: Key('group-favorites')),
                    for (final f in idle)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _FavoriteRow(
                          favorite: f,
                          label: state.labelOf(f),
                          deviceName: state.deviceName(f.device),
                          onTap: state.hubUsable ? () => state.openOrSwitch(f.device, f.bundle, f.name) : null,
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

/// A favourite with no session: 60px, dashed outline, not-opened lamp (K9).
class _FavoriteRow extends StatelessWidget {
  const _FavoriteRow({required this.favorite, required this.label, required this.deviceName, required this.onTap});
  final AppRef favorite;
  final String label;
  final String deviceName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    return SizedBox(
      key: Key('favorite-${favorite.key}'),
      height: 60,
      child: Semantics(
        button: true,
        label: '$label @ $deviceName，${lampWord(Lamp.notOpened)}',
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(t.r),
            child: CustomPaint(
              foregroundPainter: DashedOutline(t.line, t.r),
              child: Container(
                decoration: t.panelBox(border: Colors.transparent),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const ExcludeSemantics(child: StatusLamp(Lamp.notOpened)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            deviceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: small?.copyWith(color: t.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
