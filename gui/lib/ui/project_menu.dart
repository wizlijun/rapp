// The top bar's project control, ahead of the session list: one button naming the current project,
// and a menu to switch. It shows only when there are two projects or more to switch between.
import 'package:flutter/material.dart';

import 'main_state.dart';
import 'rule_snack.dart';
import 'tokens.dart';

class ProjectMenu extends StatelessWidget {
  const ProjectMenu({super.key, required this.state, this.compact = false});

  final MainState state;

  /// No room for the name: the icon and the ▾ alone, the name in the tooltip.
  final bool compact;

  /// The button's widest with the name, and its width without.
  static const fullWidth = 160.0;
  static const compactWidth = 48.0;

  /// Shown only with something to switch between.
  static bool shows(MainState state) => state.projects.length >= 2;

  static const noneLabel = '未选项目';

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final current = state.projects.where((p) => p.id == state.currentProject).firstOrNull;
    final label = current?.name ?? noneLabel;
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
                  decoration: BoxDecoration(borderRadius: radius, border: Border.all(color: t.line)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_outlined, size: 16, color: t.muted),
                      if (!compact) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            label,
                            key: const Key('project-menu-label'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: current == null ? t.muted : t.text),
                          ),
                        ),
                      ],
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

  /// The menu under the button: every project, the current one ticked, the previous one marked.
  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final t = RappTokens.of(context);
    final pick = await showMenu<String>(
      context: context,
      position: menuAt(context, at),
      items: [
        for (final p in state.projects)
          PopupMenuItem<String>(
            key: Key('project-row-${p.id}'),
            value: p.id,
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: p.id == state.currentProject
                      ? Icon(Icons.check, size: 16, color: Theme.of(context).colorScheme.onSurface)
                      : null,
                ),
                Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (p.id == state.previousProject) ...[
                  const SizedBox(width: 12),
                  Text('上一个', style: TextStyle(color: t.muted)),
                ],
              ],
            ),
          ),
      ],
    );
    if (pick == null || pick == state.currentProject) return;
    state.switchProject(pick);
  }
}
