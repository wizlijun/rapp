// The top bar's project control, ahead of the session list: one button naming what the list is
// narrowed to, and a menu to switch: 全部, 自由区 (the sessions in no project), then each project.
// It shows once there is a project.
import 'package:flutter/material.dart';

import 'main_state.dart';
import 'rule_snack.dart';
import 'tokens.dart';

class ProjectMenu extends StatelessWidget {
  const ProjectMenu({super.key, required this.state, this.compact = false});

  final MainState state;

  /// No room for the name: the icon and the ▾, the name in the tooltip.
  final bool compact;

  /// The button's widest with the name, and its width without.
  static const fullWidth = 160.0;
  static const compactWidth = 48.0;

  /// Shown once there is a project: with it, 全部 and 自由区 are already three to pick from.
  static bool shows(MainState state) => state.projects.isNotEmpty;

  /// The menu's values for 全部 and 自由区; project ids never start with a NUL.
  static const allValue = '\u0000all';
  static const freeZoneValue = '\u0000freeZone';

  /// Each choice's icon: 全部 every app, a project a workspace, 自由区 open land.
  static const allIcon = Icons.apps;
  static const projectIcon = Icons.workspaces_outlined;
  static const freeZoneIcon = Icons.landscape_outlined;

  /// The button's icon: the working sphere, whatever it is narrowed to.
  static const buttonIcon = Icons.workspaces_outlined;

  /// What the button names: the current project, 自由区, or 全部.
  static String labelOf(MainState state) {
    if (state.freeZone) return MainState.freeZoneLabel;
    return state.projects.where((p) => p.id == state.currentProject).firstOrNull?.name ?? MainState.allLabel;
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final label = labelOf(state);
    final radius = BorderRadius.circular(t.r);
    return Tooltip(
      message: '项目：$label',
      child: Semantics(
        key: const Key('project-menu'),
        button: true,
        label: '项目：$label',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: compact ? compactWidth : fullWidth),
          child: Material(
            type: MaterialType.transparency,
            child: Builder(
              builder: (btn) => InkWell(
                onTap: () => _open(btn),
                borderRadius: radius,
                child: Container(
                  // Hugs its content: a short name keeps a short button.
                  constraints: const BoxConstraints(minHeight: 48, maxHeight: 48, minWidth: 48),
                  padding: EdgeInsets.only(left: compact ? 4 : 10, right: compact ? 2 : 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(buttonIcon, key: const Key('project-menu-icon'), size: 18, color: t.muted),
                      const SizedBox(width: 6),
                      if (!compact) Flexible(
                        child: Text(
                          label,
                          key: const Key('project-menu-label'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.text),
                        ),
                      ),
                      Icon(Icons.arrow_drop_down, size: 18, color: t.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The menu under the button: 全部, 自由区, every project, each with its icon. The current one is
  /// bold, the previous project marked 上一个.
  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final t = RappTokens.of(context);
    final now = state.freeZone ? freeZoneValue : state.currentProject ?? allValue;
    PopupMenuItem<String> row(String key, String value, IconData icon, String name, {bool previous = false}) =>
        PopupMenuItem<String>(
          key: Key(key),
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 18, color: value == now ? t.text : t.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: value == now ? FontWeight.w700 : null),
                ),
              ),
              if (previous) ...[
                const SizedBox(width: 12),
                Text('上一个', style: TextStyle(color: t.muted)),
              ],
            ],
          ),
        );
    final pick = await showMenu<String>(
      context: context,
      position: menuAt(context, at),
      items: [
        row('project-row-all', allValue, allIcon, MainState.allLabel),
        row('project-row-free-zone', freeZoneValue, freeZoneIcon, MainState.freeZoneLabel),
        for (final p in state.projects)
          row('project-row-${p.id}', p.id, projectIcon, p.name, previous: p.id == state.previousProject),
      ],
    );
    if (pick == null || pick == now) return;
    if (pick == allValue) return state.leaveProject();
    if (pick == freeZoneValue) return state.switchFreeZone();
    state.switchProject(pick);
  }
}
