// The top bar's project control, ahead of the session list: one button naming what the list is
// narrowed to, and a menu to switch: 全部, 自由区 (the sessions in no project), then each project.
// It shows once there is a project.
import 'package:flutter/material.dart';

import 'main_state.dart';
import 'controls.dart';
import 'tokens.dart';

class ProjectMenu extends StatelessWidget {
  const ProjectMenu({super.key, required this.state, this.compact = false});

  final MainState state;

  /// No room for the name: the icon and the ▾, the name in the tooltip.
  final bool compact;

  /// The button's widest with the name, and its width without.
  static const fullWidth = 160.0;
  static const compactWidth = 56.0;

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
    final now = state.freeZone ? freeZoneValue : state.currentProject ?? allValue;
    RappMenuItem<String> row(String key, String value, IconData icon, String name, {bool previous = false}) =>
        RappMenuItem<String>(
          key: Key(key),
          value: value,
          label: name,
          lead: Icon(icon, size: 18, color: value == now ? t.text : t.muted),
          trailing: previous ? Text('上一个', style: TextStyle(color: t.muted)) : null,
        );
    return Tooltip(
      message: '项目：$label',
      child: Semantics(
        key: const Key('project-menu'),
        button: true,
        label: '项目：$label',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: compact ? compactWidth : fullWidth),
          child: RappDropdown<String>(
            current: now,
            label: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(buttonIcon, key: const Key('project-menu-icon'), size: 18, color: t.muted),
              if (!compact) ...[
                const SizedBox(width: 6),
                Flexible(child: Text(label, key: const Key('project-menu-label'))),
              ],
            ]),
            items: [
              row('project-row-all', allValue, allIcon, MainState.allLabel),
              row('project-row-free-zone', freeZoneValue, freeZoneIcon, MainState.freeZoneLabel),
              for (final p in state.projects)
                row('project-row-${p.id}', p.id, projectIcon, p.name, previous: p.id == state.previousProject),
            ],
            onSelected: (pick) {
              if (pick == now) return;
              if (pick == allValue) return state.leaveProject();
              if (pick == freeZoneValue) return state.switchFreeZone();
              state.switchProject(pick);
            },
          ),
        ),
      ),
    );
  }
}
