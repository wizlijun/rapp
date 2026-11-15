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
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final devices = state.panel == PanelTab.devices;
        final projects = state.panel == PanelTab.projects;
        final resources = state.panel == PanelTab.resources;
        final width = math.min(devices || projects || resources ? 720.0 : 330.0, mq.width);
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
              builder: (context, box) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                    child: Row(
                      children: [
                        // The tabs share the row; the close button keeps its own 48 px.
                        Expanded(
                          child: Row(
                            children: [
                              for (final (i, tab) in tabOrder(state.prefs.first).indexed) ...[
                                if (i > 0) const SizedBox(width: 6),
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 96),
                                    child: TabChip(
                                      key: Key('tab-${tab.name}'),
                                      label: _tabLabel(tab),
                                      selected: _selected(tab),
                                      onTap: () => _tab(tab),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
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
                    constraints: BoxConstraints(maxHeight: box.maxHeight * .6),
                    child: SingleChildScrollView(child: _Footer(state: state)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
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
                        style: TextStyle(color: t.muted, fontSize: 12),
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
        Text(label, style: TextStyle(color: t.muted, fontSize: 12)),
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
