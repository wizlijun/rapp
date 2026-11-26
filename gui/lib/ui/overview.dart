// The overview (全景): status counts, the device wall, and (Task 4) the project/resource layer.
// It takes the stage's place; the top bar and overlays stay as they are.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../embed/traffic_label.dart';
import '../service_client.dart';
import 'inbound.dart';
import 'lamp.dart';
import 'os_mark.dart';
import 'main_state.dart';
import 'open_apps_menu.dart';
import 'overview_model.dart';
import 'prefs.dart' show FirstLayer;
import 'projects.dart' show orderedProjects;
import 'session_block.dart';
import 'term_restore_dialog.dart' show showTermRestore;
import 'workspace_store.dart';
import 'tokens.dart';

const _gap = 12.0;
const _colWidth = 220.0;
const _cellWidth = 150.0;

/// Height of the counts row and of the project/resource row.
const _bandHeight = 88 + 2 * _gap;

/// The corner illustration's largest side, in logical pixels.
const overviewArtMaxSide = 440.0;

class Overview extends StatelessWidget {
  const Overview({super.key, required this.state, this.monitor});
  final MainState state;

  /// This machine's service: who is in (正在被接入, on the 本机 column). Null where there is none (iOS).
  final ServiceMonitor? monitor;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.resources, ?monitor]),
      builder: (context, _) {
        final entries = state.entries;
        final hosts = state.hub?.hosts ?? const [];
        final counts = overviewCounts(entries, online: state.onlineDevices, devices: state.deviceCount);
        final cols = deviceColumns(
          hosts: hosts,
          probes: state.probes,
          // The labelled sessions that are not open stand at the end of their device's column (not counted).
          entries: state.listed,
          name: state.deviceName,
          localVersion: state.hub?.version,
          localOs: state.localOs,
        );
        final projectsFirst = state.prefs.first == FirstLayer.project;
        return Stack(children: [
          Positioned.fill(child: OverviewArt(projectsFirst: projectsFirst)),
          // The page scrolls up and down; the wall wraps its columns into rows when they do not fit across
          // (iPad spec §7.2). With room to spare the project/resource row still sits at the bottom.
          CustomScrollView(key: const Key('overview'), slivers: [
            SliverToBoxAdapter(child: _CountsRow(state: state, counts: counts)),
            if (projectsFirst) SliverToBoxAdapter(child: _ThirdLayer(state: state)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: _gap),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  key: const Key('wall'),
                  spacing: _gap,
                  runSpacing: _gap,
                  children: [for (final c in cols) _Column(state: state, col: c, monitor: monitor)],
                ),
              ),
            ),
            if (!projectsFirst)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Align(alignment: Alignment.bottomCenter, child: _ThirdLayer(state: state)),
              )
            else
              const SliverToBoxAdapter(child: SizedBox(height: _gap)),
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
  const OverviewArt({super.key, this.projectsFirst = false});

  /// The project row is above the wall, so the wall's corner is the bottom edge.
  final bool projectsFirst;

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
          bottom: projectsFirst ? 0 : _bandHeight,
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
              // 本机 is always up and counted; the lamp goes out when every added device is off.
              lamp: c.devices > 1 && c.online <= 1 ? Lamp.offline : Lamp.active,
              value: '${c.online}/${c.devices}',
              muted: c.devices > 1 && c.online <= 1,
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
          Text(label, maxLines: 1, style: TextStyle(color: t.muted)),
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
  const _Column({required this.state, required this.col, this.monitor});
  final MainState state;
  final DeviceColumn col;
  final ServiceMonitor? monitor;

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
              OsMark(col.os, key: Key('os-mark-${id ?? 'local'}')),
              const SizedBox(width: 6),
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
        // The sessions, then this device's favourites that are not open (one tap opens one). The page scrolls,
        // so the column is as tall as what it holds.
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (col.entries.isEmpty) Text('没有打开的 app', style: TextStyle(color: t.muted)),
          for (final (i, e) in col.entries.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            SessionBlock(state: state, entry: e),
          ],
          // Who is in on this machine: not tasks, so they follow the sessions and open nothing.
          if (id == null && monitor != null)
            InboundGroup(
              sessions: monitor!.status?.sessions ?? const [],
              hosts: state.hub?.hosts ?? const [],
              now: state.now,
              onKick: monitor!.kick,
              labels: monitor!.labels == null
                  ? null
                  : LocalLabels(
                      table: monitor!.labels!,
                      set: (app, title, note) => monitor!.setLabel(app, title: title, note: note),
                      reset: monitor!.resetLabel,
                      say: state.say,
                    ),
            ),
          if (favorites.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 6),
              child: Text('常用', style: small?.copyWith(color: t.muted, letterSpacing: t.labelSpacing * t.textSize)),
            ),
            for (final (i, f) in favorites.indexed) ...[
              if (i > 0) const SizedBox(height: 8),
              FavoriteBlock(
                favorite: f,
                label: state.labelOf(f),
                verb: state.favoriteVerb(f),
                onTap: state.hubUsable && !col.offline
                    ? () => state.favoriteVerb(f) == '恢复' ? showTermRestore(context, state, f.device) : state.openFavorite(f)
                    : null,
              ),
            ],
          ],
        ]),
        // The version, and on a remote column 打开应用 at the right: all its apps in one menu.
        if (col.version != null || id != null)
          Padding(
            padding: EdgeInsets.only(top: id == null ? 14 : 6),
            child: Row(children: [
              Expanded(
                child: col.version == null
                    ? const SizedBox.shrink()
                    : Text(col.version!,
                        key: Key('version-${id ?? 'local'}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: small?.copyWith(color: t.muted)),
              ),
              if (id != null) _OpenAppsLink(id: id, name: col.name, enabled: state.hubUsable && !col.offline, state: state),
            ]),
          ),
      ]),
    );
  }
}

/// 「打开应用 ▾」at the foot of a remote column; a tap opens the device's app menu right under it.
class _OpenAppsLink extends StatelessWidget {
  const _OpenAppsLink({required this.id, required this.name, required this.enabled, required this.state});
  final String id;
  final String name;
  final bool enabled;
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final color = enabled ? t.on : t.muted.withValues(alpha: 0.6);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: color);
    return Builder(builder: (anchor) {
      final onTap = enabled ? () => showOpenAppsMenu(anchor, state, id) : null;
      return Semantics(
        button: true,
        enabled: enabled,
        label: '打开应用，$name',
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          key: Key('open-apps-$id'),
          borderRadius: BorderRadius.circular(t.r),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('打开应用', style: style),
                Icon(Icons.arrow_drop_down, size: 18, color: color),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

const _projectCellWidth = 200.0;
const _resourcesWidth = 300.0;

/// Projects (scrolling) on the left, the resources cell pinned to the right (K13); no projects, no cell.
class _ThirdLayer extends StatelessWidget {
  const _ThirdLayer({required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final projects = orderedProjects(state.projects);
    return SizedBox(
      height: 88 + 2 * _gap,
      child: Row(children: [
        Expanded(
          // No projects: nothing here, not even a word (project spec §5).
          child: projects.isEmpty
              ? const SizedBox.shrink()
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
