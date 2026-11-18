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
import 'controls.dart';
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

/// The panel's width in a [window] this wide: half of it, the same for every tab.
double panelWidth(double window) => window / 2;

/// 全局设置's rows (the dropdowns, the switch rows and the fold header): the same height as every control.
double settingsRowHeight(TargetPlatform p) => controlHeightFor(p);

/// 全局设置's text size: one step under the panel's [text] size.
double settingsTextSize(double text) => math.max(11, text - 1);

class SidePanel extends StatelessWidget {
  const SidePanel({super.key, required this.state, required this.devicesTab, this.settings});
  final MainState state;
  final Widget devicesTab;

  /// More of 全局设置 under its switches (版本升级, 数据目录); folds with them.
  final Widget? settings;

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
        final width = math.min(math.max(panelWidth(mq.width), navigationWidth), mq.width);
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
                    child: SingleChildScrollView(child: _Footer(state: state, settings: settings)),
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
  const _Footer({required this.state, this.settings});
  final MainState state;
  final Widget? settings;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    // 全局设置 is secondary: a step smaller than the panel's text, on 34px rows. A dropdown's style replaces the
    // theme's text style instead of merging into it, so the size and font are given in full.
    final small = Theme.of(context).textTheme.bodyMedium!.copyWith(
          color: t.text, fontSize: settingsTextSize(t.textSize), height: 1.3);
    final folded = state.prefs.settingsFolded;
    final rowHeight = settingsRowHeight(Theme.of(context).platform);
    Widget box<T>(Key key, T value, List<(T, String)> items, void Function(T) onChanged) => RappDropdown<T>(
          key: key,
          expand: true,
          current: value,
          label: Text(items.firstWhere((e) => e.$1 == value).$2, style: small),
          items: [for (final (v, label) in items) RappMenuItem<T>(value: v, label: label)],
          onSelected: onChanged,
        );
    Widget toggle(Key key, String label, bool value, void Function(bool) onChanged, {String? note}) =>
        RappSwitchRow(key: key, label: label, note: note, value: value, onChanged: onChanged, style: small);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 全局设置 folds away; the legend and the totals below always show.
          InkWell(
            key: const Key('settings-fold'),
            borderRadius: BorderRadius.circular(t.r),
            onTap: () => state.setSettingsFolded(!folded),
            child: SizedBox(
              height: rowHeight,
              child: Row(children: [
                Icon(folded ? Icons.chevron_right : Icons.expand_more, color: t.muted, size: 18),
                const SizedBox(width: 4),
                Text('全局设置', style: small.copyWith(color: t.muted)),
              ]),
            ),
          ),
          if (!folded) Column(key: const Key('global-settings'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 4),
            box(const Key('theme-dropdown'), state.prefs.theme, [for (final th in themeOrder) (th, themeLabel(th))],
                state.setTheme),
            const SizedBox(height: 6),
            box(const Key('first-dropdown'), state.prefs.first,
                const [(FirstLayer.device, '设备在前'), (FirstLayer.project, '项目在前')], state.setFirst),
            const SizedBox(height: 4),
            toggle(const Key('start-fullscreen'), '启动时全屏', state.prefs.startFullscreen, state.setStartFullscreen),
            toggle(const Key('auto-save-traffic'), '网络差时自动省流量', state.prefs.autoSaveTraffic,
                state.setAutoSaveTraffic),
            toggle(const Key('input-history'), '记下写作面板发出去的话', state.prefs.inputHistory, state.setInputHistory,
                note: '存在数据目录的 inputs/ 里，会随 git 同步'),
            if (settings != null) ...[const SizedBox(height: 8), settings!],
          ]),
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
