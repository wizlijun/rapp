// Left side panel shell: tabs, tab content, and a fixed footer with the
// theme picker, start-fullscreen switch, lamp legend and totals.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../embed/traffic_label.dart' show formatRate;
import 'lamp.dart';
import 'main_state.dart';
import 'prefs.dart' show FirstLayer;
import 'projects_tab.dart';
import 'resources_tab.dart';
import 'sessions_tab.dart';
import 'tab_chip.dart';
import 'tokens.dart';

/// The panel's tabs, left to right: the preferred layer comes right after the sessions.
List<PanelTab> tabOrder(FirstLayer f) => [
      PanelTab.sessions,
      if (f == FirstLayer.project) ...[PanelTab.projects, PanelTab.devices] else ...[PanelTab.devices, PanelTab.projects],
      PanelTab.resources,
    ];

String _tabLabel(PanelTab t) => switch (t) {
      PanelTab.sessions => '会话',
      PanelTab.devices => '设备',
      PanelTab.projects => '项目',
      PanelTab.resources => '资源',
    };

class SidePanel extends StatelessWidget {
  const SidePanel({super.key, required this.state, required this.devicesTab});
  final MainState state;
  final Widget devicesTab;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final mq = MediaQuery.sizeOf(context);
    final tabSize = _minimumTabSize(context);
    final tabWidth = tabSize.width;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final devices = state.panel == PanelTab.devices;
        final projects = state.panel == PanelTab.projects;
        final resources = state.panel == PanelTab.resources;
        // Keep the Mac layout at the default size, but reserve enough logical
        // width for the actual font metrics/text scale on every desktop.
        final navigationWidth = 4 * tabWidth + 3 * 6 + 48 + 22;
        final width = math.min(math.max(devices || projects || resources ? 720.0 : 330.0, navigationWidth), mq.width);
        return Container(
          width: width,
          decoration: BoxDecoration(
            color: t.bg,
            border: Border(right: BorderSide(color: t.text)),
            boxShadow: const [
              BoxShadow(color: Color(0x99000000), blurRadius: 24),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: LayoutBuilder(
              builder: (context, box) {
                final columns = _navigationColumns(box.maxWidth - 20 - 48, tabWidth);
                final rows = (PanelTab.values.length / columns).ceil();
                final headerHeight = 10.0 + math.max(48.0, tabSize.height * rows + (rows - 1) * 6);
                // At the legal minimum window height, wrapped navigation must
                // not fight the footer's 60% cap. Keep the body usable and make
                // the whole panel scroll only when these minimums cannot fit.
                final height = math.max(box.maxHeight, headerHeight + 100 + 48);
                final footerHeight = math.min(height * .6, height - headerHeight - 100);
                final contents = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // The tabs share the row; the close button keeps its own 48 px.
                          Expanded(
                            child: LayoutBuilder(builder: (context, available) {
                              final tabs = tabOrder(state.prefs.first);
                              Widget chip(PanelTab tab) => TabChip(
                                key: Key('tab-${tab.name}'), label: _tabLabel(tab),
                                selected: _selected(tab), onTap: () => _tab(tab),
                            );
                            if (available.maxWidth >= tabs.length * tabWidth + (tabs.length - 1) * 6) {
                              return Row(children: [
                                for (final (i, tab) in tabs.indexed) ...[
                                  if (i > 0) const SizedBox(width: 6),
                                  Flexible(child: ConstrainedBox(
                                    constraints: BoxConstraints(maxWidth: math.max(96, tabWidth)), child: chip(tab))),
                                ],
                              ]);
                            }
                            // A narrow window cannot grow with the text. Wrap
                            // whole tabs instead of ellipsizing their only labels.
                            final columns = _navigationColumns(available.maxWidth, tabWidth);
                            final width = (available.maxWidth - (columns - 1) * 6) / columns;
                            return Wrap(spacing: 6, runSpacing: 6, children: [
                              for (final tab in tabs) SizedBox(width: width, child: chip(tab)),
                            ]);
                          }),
                        ),
                        IconButton(
                          key: const Key('panel-close'),
                          tooltip: '收起面板',
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          icon: Icon(Icons.chevron_left, color: t.text),
                          onPressed: state.closePanel,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: devices
                        ? devicesTab
                        : projects
                        ? ProjectsTab(state: state)
                        : resources
                        ? ResourcesTab(state: state)
                        : SessionsTab(state: state),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: footerHeight),
                    child: SingleChildScrollView(child: _Footer(state: state)),
                  ),
                ],
                );
                // Keep the same ancestry across height changes so resizing does
                // not recreate editors in the device/project tabs.
                return SingleChildScrollView(primary: false, child: SizedBox(height: height, child: contents));
              },
            ),
          ),
        );
      },
    );
  }

  int _navigationColumns(double available, double tabWidth) {
    final fitting = ((available + 6) / (tabWidth + 6)).floor();
    return fitting >= PanelTab.values.length ? PanelTab.values.length : fitting >= 2 ? 2 : 1;
  }

  Size _minimumTabSize(BuildContext context) {
    var width = 48.0;
    var height = 48.0;
    for (final tab in PanelTab.values) {
      // Selected and unselected glyphs can have different widths with real fonts.
      for (final weight in [FontWeight.w400, FontWeight.w600]) {
        final painter = TextPainter(
          text: TextSpan(text: _tabLabel(tab), style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: weight)),
          textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context), maxLines: 1,
        )..layout();
        // TabChip has 12px padding and a 1px border on each side.
        width = math.max(width, (painter.width + 26).ceilToDouble());
        height = math.max(height, (painter.height + 2).ceilToDouble());
        painter.dispose();
      }
    }
    return Size(width, height);
  }

  bool _selected(PanelTab tab) => tab == PanelTab.sessions
      ? state.panel == null || state.panel == PanelTab.sessions
      : state.panel == tab;

  void _tab(PanelTab tab) {
    if (state.panel != tab) state.togglePanel(tab);
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(t.r),
              border: Border.all(color: t.line),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<RappTheme>(
                key: const Key('theme-dropdown'),
                value: state.prefs.theme,
                isExpanded: true,
                itemHeight: 48,
                dropdownColor: t.bg,
                iconEnabledColor: t.text,
                style: TextStyle(color: t.text),
                items: [
                  for (final th in themeOrder)
                    DropdownMenuItem(value: th, child: Text(themeLabel(th))),
                ],
                onChanged: (v) {
                  if (v != null) state.setTheme(v);
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(t.r),
              border: Border.all(color: t.line),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<FirstLayer>(
                key: const Key('first-dropdown'),
                value: state.prefs.first,
                isExpanded: true,
                itemHeight: 48,
                dropdownColor: t.bg,
                iconEnabledColor: t.text,
                style: TextStyle(color: t.text),
                items: const [
                  DropdownMenuItem(value: FirstLayer.device, child: Text('设备在前')),
                  DropdownMenuItem(value: FirstLayer.project, child: Text('项目在前')),
                ],
                onChanged: (v) {
                  if (v != null) state.setFirst(v);
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            key: const Key('start-fullscreen'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text('启动时全屏', style: TextStyle(color: t.text)),
            value: state.prefs.startFullscreen,
            onChanged: state.setStartFullscreen,
          ),
          SwitchListTile(
            key: const Key('auto-save-traffic'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text('网络差时自动省流量', style: TextStyle(color: t.text)),
            value: state.prefs.autoSaveTraffic,
            onChanged: state.setAutoSaveTraffic,
          ),
          SwitchListTile(
            key: const Key('input-history'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text('记下写作面板发出去的话', style: TextStyle(color: t.text)),
            subtitle: Text('存在数据目录的 inputs/ 里，会随 git 同步', style: TextStyle(color: t.muted)),
            value: state.prefs.inputHistory,
            onChanged: state.setInputHistory,
          ),
          const SizedBox(height: 6),
          // The legend explains shapes; motion is kept for things that need
          // you (design language §1), so its lamps stand still.
          MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Wrap(
              key: const Key('legend'),
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final l in Lamp.values)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusLamp(l),
                      const SizedBox(width: 4),
                      Text(
                        lampWord(l),
                        style: TextStyle(color: t.muted),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _Total(
                '在线设备',
                '${state.onlineDevices}',
                const Key('total-online'),
                state.deviceCount > 1 && state.remoteOnline == 0,
              ),
              _Total(
                '会话',
                '${state.sessionCount}',
                const Key('total-sessions'),
                state.sessionCount == 0,
              ),
              _Total(
                '总流量',
                state.embeds ? formatRate(state.totalBytesPerSecond) : '—',
                const Key('total-traffic'),
                state.embeds && state.totalBytesPerSecond == 0,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total(this.label, this.value, this.valueKey, this.zero);
  final String label;
  final String value;
  final Key valueKey;
  final bool zero;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: t.muted)),
        Text(
          value,
          key: valueKey,
          style: TextStyle(
            fontFamily: t.mono,
            fontFamilyFallback: t.monoFallback,
            fontSize: 30,
            fontWeight: FontWeight.w600,
            color: zero ? t.muted : t.text,
          ),
        ),
      ],
    );
  }
}
