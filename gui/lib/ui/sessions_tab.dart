// Sessions tab of the side panel: grouping switch and 60px session rows.
import 'package:flutter/material.dart';

import '../embed/traffic_label.dart' show formatRate;
import 'controls.dart' show DashedOutline;
import 'lamp.dart';
import 'main_state.dart';
import 'session_model.dart';
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
                    _GroupTitle(g.title),
                    for (final e in g.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _SessionRow(
                          entry: e,
                          selected: e.key == state.currentKey,
                          byDevice: state.grouping == Grouping.device,
                          embedded: state.embeds,
                          onTap: () => state.select(e.key),
                        ),
                      ),
                  ],
                  if (idle.isNotEmpty) ...[
                    const _GroupTitle('常用', key: Key('group-favorites')),
                    for (final f in idle)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _FavoriteRow(
                          favorite: f,
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

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: t.muted, letterSpacing: 11 * t.labelSpacing),
      ),
    );
  }
}

/// A favourite with no session: 60px, dashed outline, not-opened lamp (K9).
class _FavoriteRow extends StatelessWidget {
  const _FavoriteRow({required this.favorite, required this.deviceName, required this.onTap});
  final AppRef favorite;
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
        label: '${favorite.name} @ $deviceName，${lampWord(Lamp.notOpened)}',
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
                            favorite.name,
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

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.entry,
    required this.selected,
    required this.byDevice,
    required this.embedded,
    required this.onTap,
  });
  final SessionEntry entry;
  final bool selected;
  final bool byDevice;

  /// Only embedded sessions have traffic data; other rows are unchanged (R22).
  final bool embedded;
  final VoidCallback onTap;

  String get _second {
    final path = pathLabels[entry.path] ?? '';
    if (byDevice) return path;
    return path.isEmpty ? entry.device : '${entry.device} · $path';
  }

  /// The status text at the row's right (R22): the rate when active, 「空闲」, 「连接中」; empty
  /// when disconnected (its reason takes the second line) or when there is no data.
  String get _status {
    if (!embedded || entry.reason != null) return '';
    return switch (entry.lamp) {
      Lamp.active => entry.bytesPerSecond == null ? '' : formatRate(entry.bytesPerSecond!),
      Lamp.idle => '空闲',
      Lamp.connecting => '连接中',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final backdrop = rowBackdrop(entry.lamp, t);
    final border = rowBorder(entry.lamp, t, selected: selected);
    final reason = entry.reason == null ? null : '已断开：${entry.reason}';
    final second = reason ?? _second;
    final status = _status;
    final label = [
      entry.appName,
      // The state word is said once: 「空闲」 and 「连接中」 are both lamp and status.
      if (status != lampWord(entry.lamp)) lampWord(entry.lamp),
      if (status.isNotEmpty) status,
      if (second.isNotEmpty) second,
    ].join('，');
    final small = Theme.of(context).textTheme.bodySmall;
    return SizedBox(
      key: Key('session-${entry.key}'),
      height: 60,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(t.r),
            child: Container(
              decoration: t.panelBox(border: border),
              child: Stack(
                children: [
                  if (backdrop != null)
                    Positioned.fill(child: DecoratedBox(decoration: backdrop)),
                  if (selected)
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: DecoratedBox(
                          key: Key('inner-stroke-${entry.key}'),
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular((t.r - 2).clamp(0, t.r)),
                            border: Border.all(color: t.text),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        StatusLamp(entry.lamp),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.appName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: t.text,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (second.isNotEmpty)
                                Text(
                                  second,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: small?.copyWith(color: t.muted),
                                ),
                            ],
                          ),
                        ),
                        if (embedded && (entry.reason != null || status.isNotEmpty))
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              status,
                              key: Key('session-status-${entry.key}'),
                              maxLines: 1,
                              style: TextStyle(
                                fontFamily: t.mono,
                                fontFamilyFallback: t.monoFallback,
                                fontSize: 12,
                                color: t.muted,
                              ),
                            ),
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
    );
  }
}
