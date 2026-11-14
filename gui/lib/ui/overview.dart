// The overview (全景): status counts, the device wall, and (Task 4) the project/resource layer.
// It takes the stage's place; the top bar and overlays stay as they are.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../embed/traffic_label.dart';
import 'controls.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'overview_model.dart';
import 'session_model.dart';
import 'workspace_store.dart';
import 'tokens.dart';

const _gap = 12.0;
const _colWidth = 220.0;
const _cellWidth = 150.0;
const _blockHeight = 56.0;

/// Height of the counts row and of the project/resource row.
const _bandHeight = 88 + 2 * _gap;

/// The corner illustration's largest side, in logical pixels.
const overviewArtMaxSide = 440.0;

class Overview extends StatelessWidget {
  const Overview({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.resources]),
      builder: (context, _) {
        final entries = state.entries;
        final hosts = state.hub?.hosts ?? const [];
        final counts = overviewCounts(entries, online: state.onlineDevices, devices: hosts.length);
        final cols = deviceColumns(
          hosts: hosts,
          probes: state.probes,
          entries: entries,
          name: state.deviceName,
        );
        return Stack(children: [
          const Positioned.fill(child: OverviewArt()),
          Column(key: const Key('overview'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _CountsRow(state: state, counts: counts),
            Expanded(
              child: ListView.separated(
                key: const Key('wall'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: _gap),
                itemCount: cols.length,
                separatorBuilder: (_, _) => const SizedBox(width: _gap),
                itemBuilder: (_, i) => _Column(state: state, col: cols[i]),
              ),
            ),
            _ThirdLayer(state: state),
          ]),
        ]);
      },
    );
  }
}

/// The theme's illustration ([RappTokens.overviewArt]), behind the device wall's bottom-right corner,
/// just above the project/resource row. Decoration only: it takes no pointer events, is hidden from
/// screen readers, and a missing or unreadable file paints nothing.
class OverviewArt extends StatelessWidget {
  const OverviewArt({super.key});

  @override
  Widget build(BuildContext context) {
    final asset = RappTokens.of(context).overviewArtAsset;
    if (asset == null) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      // Between the counts row and the project/resource row; at most 45% of the width.
      final side = math.min(overviewArtMaxSide, math.min(c.maxWidth * .45, c.maxHeight - 2 * _bandHeight));
      if (side < 48) return const SizedBox.shrink();
      final px = (side * MediaQuery.devicePixelRatioOf(context)).round();
      return Stack(children: [
        Positioned(
          right: _gap,
          bottom: _bandHeight,
          width: side,
          height: side,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: Image.asset(
                asset,
                key: const Key('overview-art'),
                fit: BoxFit.contain,
                cacheWidth: px,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}

class _CountsRow extends StatelessWidget {
  const _CountsRow({required this.state, required this.counts});
  final MainState state;
  final OverviewCounts counts;

  @override
  Widget build(BuildContext context) {
    final c = counts;
    Widget cell(String name, Lamp lamp, int n, String label, {bool alert = false, VoidCallback? onTap}) =>
        _CountCell(
          cellKey: 'count-$name',
          lamp: lamp,
          value: '$n',
          muted: n == 0,
          label: label,
          alert: alert && n != 0,
          onTap: onTap,
        );
    // The lamps here are a summary, not a session: they stay still (K7).
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: SizedBox(
        key: const Key('counts'),
        height: 88 + 2 * _gap,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(_gap),
          children: [
            cell('active', Lamp.active, c.active, '活动'),
            const SizedBox(width: _gap),
            cell('idle', Lamp.idle, c.idle, '空闲'),
            const SizedBox(width: _gap),
            cell('connecting', Lamp.connecting, c.connecting, '连接中'),
            const SizedBox(width: _gap),
            cell('disconnected', Lamp.disconnected, c.disconnected, '已断开',
                alert: true,
                onTap: c.disconnected != 0 && state.hub != null ? () => state.showCorner(Corner.needs) : null),
            const SizedBox(width: _gap),
            cell('waiting', Lamp.waiting, c.waiting, '等你', alert: true),
            const SizedBox(width: _gap),
            _CountCell(
              cellKey: 'count-online',
              lamp: c.online == 0 ? Lamp.offline : Lamp.active,
              value: '${c.online}/${c.devices}',
              muted: c.online == 0,
              label: '设备在线',
              onTap: () => state.showPanel(PanelTab.devices),
            ),
            const SizedBox(width: _gap),
            _CountCell(
              cellKey: 'count-traffic',
              bars: state.embeds ? state.totalBytesPerSecond : 0,
              value: state.embeds ? formatRate(state.totalBytesPerSecond) : '—',
              muted: false,
              label: '总流量',
              small: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _CountCell extends StatelessWidget {
  const _CountCell({
    required this.cellKey,
    this.lamp,
    this.bars,
    required this.value,
    required this.muted,
    required this.label,
    this.alert = false,
    this.small = false,
    this.onTap,
  });

  final String cellKey;
  final Lamp? lamp;

  /// Set instead of [lamp] for the traffic cell.
  final int? bars;
  final String value;
  final bool muted;
  final String label;

  /// Nonzero 已断开/等你: accent frame and backdrop.
  final bool alert;

  /// A longer value (a rate) that does not fit 30px.
  final bool small;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final radius = BorderRadius.circular(t.r);
    final backdrop = alert && lamp != null ? rowBackdrop(lamp!, t) : null;
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bars != null) LevelBars(bars!) else StatusLamp(lamp!, size: 14),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: t.mono,
              fontFamilyFallback: t.monoFallback,
              fontSize: small ? 18 : 30,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: muted ? t.muted : t.text,
            ),
          ),
          Text(label, maxLines: 1, style: TextStyle(fontSize: 12, color: t.muted)),
        ],
      ),
    );
    final frame = Container(
      key: Key('frame-$cellKey'),
      decoration: t.panelBox(border: alert ? t.accent : t.line),
      child: Stack(children: [
        if (backdrop != null) Positioned.fill(child: DecoratedBox(decoration: backdrop)),
        body,
      ]),
    );
    return SizedBox(
      key: Key(cellKey),
      width: _cellWidth,
      height: 88,
      child: onTap == null
          ? Semantics(container: true, label: '$label $value', excludeSemantics: true, child: frame)
          : Semantics(
              button: true,
              label: '$label $value',
              excludeSemantics: true,
              onTap: onTap,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: onTap, borderRadius: radius, child: frame),
              ),
            ),
    );
  }
}

class _Column extends StatelessWidget {
  const _Column({required this.state, required this.col});
  final MainState state;
  final DeviceColumn col;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final id = col.id;
    final small = Theme.of(context).textTheme.bodySmall;
    final favorites = id == null ? const <AppRef>[] : [for (final f in state.idleFavorites) if (f.device == id) f];
    return SizedBox(
      key: Key('column-${id ?? 'local'}'),
      width: _colWidth,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              col.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w600, color: col.offline ? t.muted : t.text),
            ),
            const SizedBox(height: 2),
            Row(children: [
              StatusLamp(col.lamp),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  col.path.isEmpty ? col.word : '${col.word} · ${col.path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(color: t.muted),
                ),
              ),
            ]),
          ]),
        ),
        Expanded(
          // The sessions, then this device's favourites that are not open (one tap opens one).
          child: ListView(children: [
            if (col.entries.isEmpty) Text('没有打开的 app', style: TextStyle(color: t.muted)),
            for (final (i, e) in col.entries.indexed) ...[
              if (i > 0) const SizedBox(height: 8),
              _Block(state: state, entry: e),
            ],
            if (favorites.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Text('常用', style: small?.copyWith(color: t.muted, letterSpacing: t.labelSpacing * 12)),
              ),
              for (final (i, f) in favorites.indexed) ...[
                if (i > 0) const SizedBox(height: 8),
                _FavoriteBlock(
                  favorite: f,
                  onTap: state.hubUsable && !col.offline ? () => state.openOrSwitch(f.device, f.bundle, f.name) : null,
                ),
              ],
            ],
            if (col.entries.isEmpty && id != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: RappButton.secondary(
                  key: Key('open-app-$id'),
                  label: '打开 app',
                  onPressed: () => state.showDevice(id),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// A favourite that is not open: dashed, 「点按打开」; greyed while it cannot open.
class _FavoriteBlock extends StatelessWidget {
  const _FavoriteBlock({required this.favorite, required this.onTap});
  final AppRef favorite;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final radius = BorderRadius.circular(t.r);
    return SizedBox(
      key: Key('ov-favorite-${favorite.key}'),
      height: 48,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: '常用 ${favorite.name}，${onTap != null ? '点按打开' : '现在打不开'}',
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: CustomPaint(
              foregroundPainter: DashedOutline(t.line, t.r),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(children: [
                  const StatusLamp(Lamp.notOpened),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      favorite.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: onTap != null ? t.text : t.muted),
                    ),
                  ),
                  if (onTap != null) Text('打开', style: small),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.state, required this.entry});
  final MainState state;
  final SessionEntry entry;

  String get _status => switch (entry.lamp) {
        Lamp.active => '活动',
        Lamp.disconnected => entry.reason == null ? '已断开' : '已断开：${entry.reason}',
        final l => lampWord(l),
      };

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final selected = entry.key == state.currentKey;
    final backdrop = rowBackdrop(entry.lamp, t);
    final border = rowBorder(entry.lamp, t, selected: selected);
    final windows = windowsWord(state.windowsOf(entry.key));
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final rate = state.embeds && entry.lamp == Lamp.active;
    void onTap() => state.select(entry.key);
    final radius = BorderRadius.circular(t.r);
    return SizedBox(
      key: Key('block-${entry.key}'),
      height: _blockHeight,
      child: Semantics(
        button: true,
        selected: selected,
        label: [entry.appName, _status, ?windows].join('，'),
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Container(
              key: Key('frame-block-${entry.key}'),
              decoration: t.panelBox().copyWith(border: Border.all(color: border, width: selected ? 2 : 1)),
              child: Stack(children: [
                if (backdrop != null) Positioned.fill(child: DecoratedBox(decoration: backdrop)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    StatusLamp(entry.lamp),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                              child: Text(
                                entry.appName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (windows != null) Text(windows, maxLines: 1, style: small),
                          ]),
                          if (rate)
                            Row(children: [
                              LevelBars(entry.bytesPerSecond ?? 0),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  formatRate(entry.bytesPerSecond ?? 0),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: small?.copyWith(fontFamily: t.mono, fontFamilyFallback: t.monoFallback),
                                ),
                              ),
                            ])
                          else
                            Text(_status, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                        ],
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

const _projectCellWidth = 200.0;
const _resourcesWidth = 300.0;

/// Projects (scrolling) on the left, the resources cell pinned to the right (K13).
class _ThirdLayer extends StatelessWidget {
  const _ThirdLayer({required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final projects = state.projects;
    return SizedBox(
      height: 88 + 2 * _gap,
      child: Row(children: [
        Expanded(
          child: projects.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(_gap),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _Cell(
                      cellKey: 'ov-no-projects',
                      width: _projectCellWidth,
                      label: '还没有项目',
                      onTap: () => state.showPanel(PanelTab.projects),
                      child: Center(
                        child: Text('还没有项目', style: TextStyle(color: RappTokens.of(context).muted)),
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  key: const Key('ov-projects'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(_gap),
                  itemCount: projects.length,
                  separatorBuilder: (_, _) => const SizedBox(width: _gap),
                  itemBuilder: (_, i) => _ProjectCell(state: state, project: projects[i]),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, _gap, _gap, _gap),
          child: _ResourcesCell(state: state),
        ),
      ]),
    );
  }
}

/// A framed, tappable third-layer cell.
class _Cell extends StatelessWidget {
  const _Cell({
    required this.cellKey,
    required this.width,
    required this.label,
    required this.onTap,
    required this.child,
  });
  final String cellKey;
  final double width;
  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return SizedBox(
      key: Key(cellKey),
      width: width,
      height: 88,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(t.r),
            child: Container(
              decoration: t.panelBox(border: t.line),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectCell extends StatelessWidget {
  const _ProjectCell({required this.state, required this.project});
  final MainState state;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return _Cell(
      cellKey: 'ov-project-${project.id}',
      width: _projectCellWidth,
      label: project.name,
      onTap: () => state.showProject(project.id),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          project.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final m in project.members) StatusLamp(state.memberLamp(m)),
        ]),
      ]),
    );
  }
}

class _ResourcesCell extends StatelessWidget {
  const _ResourcesCell({required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final clips = clipSummary(state.resources.clips);
    final transfers = transferSummary(state.resources.running);
    return _Cell(
      cellKey: 'ov-resources',
      width: _resourcesWidth,
      label: '$clips，$transfers',
      onTap: () => state.showPanel(PanelTab.resources),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(clips, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text)),
        const SizedBox(height: 4),
        Text(transfers, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.muted)),
      ]),
    );
  }
}
