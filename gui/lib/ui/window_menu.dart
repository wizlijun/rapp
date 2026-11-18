// The top bar's window control (spec 2026-11-16-rapp-window-menu-design): one button showing the
// current window's title, and a menu to switch when there is more than one. It replaces the row of
// tab chips, which had no width to live in, and swallows the 已隐藏 N 个 chip beside it.
import 'package:flutter/material.dart';

import '../embed/session_port.dart';
import 'main_state.dart';
import 'controls.dart';
import 'rule_snack.dart';
import 'tokens.dart';

/// What the menu came back with: an action and the window it is about.
typedef _Pick = (String, int);

class WindowMenu extends StatelessWidget {
  const WindowMenu({super.key, required this.state, required this.term, this.compact = false});

  final MainState state;

  /// A terminal: the windows are panes — no ×, no window rules, no hidden group.
  final bool term;

  /// No room for a title: the icon and the window count alone, the title in the tooltip.
  final bool compact;

  /// The button's width with a title, and without.
  static const fullWidth = 200.0;
  static const compactWidth = 56.0;

  /// The windows to switch between, and the hidden ones the menu can bring back.
  static List<RemoteWindow> windowsOf(MainState state) {
    final rs = state.currentRemote;
    return rs == null || rs.detached ? const [] : rs.tabs.tabs;
  }

  static List<RemoteWindow> hiddenOf(MainState state, {required bool term}) {
    final rs = state.currentRemote;
    return rs == null || rs.detached || term ? const [] : rs.hidden;
  }

  /// The bar shows the control while the session has a window or something hidden to get back.
  static bool shows(MainState state, {required bool term}) =>
      windowsOf(state).isNotEmpty || hiddenOf(state, term: term).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final rs = state.currentRemote;
    if (rs == null) return const SizedBox.shrink();
    final windows = windowsOf(state);
    final hidden = hiddenOf(state, term: term);
    final app = state.current?.appName ?? '';
    String titleOf(RemoteWindow w) => w.title.isEmpty ? app : w.title;
    final current = windows.where((w) => w.id == rs.tabs.current).firstOrNull;
    // Everything hidden: the button stands for the hidden ones, as the old chip did.
    final label = current != null ? titleOf(current) : '已隐藏 ${hidden.length} 个';
    // Something to pick from: another window, or a hidden one to bring back.
    final canSwitch = windows.length >= 2 || hidden.isNotEmpty;
    // A hidden window holds A's focus: the same warning the 已隐藏 chip carried.
    final selected = rs.hiddenFocused || current == null;
    final tip = canSwitch ? '$label（${windows.length} 个窗口${hidden.isEmpty ? '' : '，隐藏 ${hidden.length} 个'}）' : label;
    return Tooltip(
      message: tip,
      child: Semantics(
        key: const Key('window-menu'),
        button: canSwitch,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: compact ? compactWidth : fullWidth),
          child: RappDropdown<_Pick>(
            minWidth: 48,
            enabled: canSwitch,
            selected: selected,
            // No room for the arrow when the title is already down to a count.
            arrow: canSwitch && !compact,
            current: current == null ? null : ('select', current.id),
            label: Text(compact ? '${windows.length + hidden.length}' : label, key: const Key('window-menu-label')),
            items: [
              for (final w in windows)
                RappMenuItem<_Pick>(
                  key: Key('window-row-${w.id}'),
                  value: ('select', w.id),
                  label: titleOf(w),
                  // A right-click closes this menu and opens the window rules at the pointer.
                  onSecondaryTapUp: term
                      ? null
                      : (row, d) {
                          Navigator.pop(row);
                          _rulesMenu(context, d.globalPosition, w.id);
                        },
                  trailing: term || state.isMainWindow(w.id)
                      ? null
                      : Builder(
                          builder: (row) => Semantics(
                            button: true,
                            label: '关闭 ${titleOf(w)}',
                            excludeSemantics: true,
                            child: InkWell(
                              key: Key('close-window-${w.id}'),
                              onTap: () => Navigator.pop(row, ('close', w.id)),
                              borderRadius: BorderRadius.circular(RappTokens.of(row).r),
                              child: SizedBox.square(
                                dimension: controlHeightOf(row),
                                child: const Icon(Icons.close, size: 16),
                              ),
                            ),
                          ),
                        ),
                ),
              if (hidden.isNotEmpty) ...[
                const RappMenuItem<_Pick>.divider(),
                RappMenuItem<_Pick>(value: ('', 0), enabled: false, label: '已隐藏 ${hidden.length} 个'),
                for (final w in hidden) ...[
                  RappMenuItem<_Pick>(value: ('', w.id), enabled: false, label: titleOf(w)),
                  RappMenuItem<_Pick>(value: ('show', w.id), label: '这次显示'),
                  RappMenuItem<_Pick>(value: ('unhide', w.id), label: '不再隐藏'),
                ],
              ],
            ],
            onSelected: (pick) {
              switch (pick.$1) {
                case 'select':
                  state.selectWindow(pick.$2);
                case 'close':
                  state.closeWindow(pick.$2);
                case 'show':
                  state.showHiddenOnce(pick.$2);
                case 'unhide':
                  state.unhide(pick.$2);
              }
            },
          ),
        ),
      ),
    );
  }

  /// A right-click on a row: the two window rules, as the tab chips had them.
  Future<void> _rulesMenu(BuildContext context, Offset p, int window) async {
    final messenger = ScaffoldMessenger.of(context);
    final pick = await showRappMenu<String>(
      context,
      position: menuAt(context, p),
      items: [
        RappMenuItem(value: 'hide', enabled: !state.isMainWindow(window), label: '隐藏这类窗口'),
        const RappMenuItem(value: 'noComposer', label: '这个窗口不要输入区'),
      ],
    );
    if (pick == null) return;
    final undo = pick == 'hide' ? state.hideLike(window) : state.noComposerLike(window);
    if (undo == null) return;
    ruleSnack(messenger, pick == 'hide' ? '已隐藏，可在 app 配置里改' : '已关掉这个窗口的输入区，可在 app 配置里改', undo);
  }
}
