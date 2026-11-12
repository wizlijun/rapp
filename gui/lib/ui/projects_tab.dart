// 项目 tab of the side panel (S5 K17): named groups of apps, each with an
// optional Agent task, a lamp per member, and open/switch per member.
import 'package:flutter/material.dart';

import 'controls.dart';
import 'inline_edit.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'session_model.dart';
import 'tokens.dart';
import 'workspace_store.dart';

class ProjectsTab extends StatelessWidget {
  const ProjectsTab({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final t = RappTokens.of(context);
        final projects = state.projects;
        return ListView(
          padding: const EdgeInsets.all(10),
          children: [
            _NewProject(state: state),
            const SizedBox(height: 10),
            if (projects.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '还没有项目。在上面输入名字，回车新建。',
                  style: TextStyle(color: t.muted),
                ),
              ),
            for (final p in projects) ...[
              _ProjectCard(
                key: Key('project-${p.id}'),
                state: state,
                project: p,
              ),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }
}

class _NewProject extends StatefulWidget {
  const _NewProject({required this.state});
  final MainState state;

  @override
  State<_NewProject> createState() => _NewProjectState();
}

class _NewProjectState extends State<_NewProject> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit(String v) {
    if (widget.state.createProject(v) != null) _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key('new-project'),
      controller: _c,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(hintText: '新建项目', isDense: true),
      onSubmitted: _submit,
    );
  }
}

class _ProjectCard extends StatefulWidget {
  const _ProjectCard({super.key, required this.state, required this.project});
  final MainState state;
  final Project project;

  @override
  State<_ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<_ProjectCard> {
  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final s = widget.state;
    final p = widget.project;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: t.panelBox(border: t.line),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InlineEdit(
                  key: Key('project-name-${p.id}'),
                  text: p.name,
                  semanticLabel: '项目名 ${p.name}',
                  style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
                  onCommit: (v) => s.renameProject(p.id, v),
                ),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: Row(
                  key: Key('project-lamps-${p.id}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in p.members) ...[
                      StatusLamp(s.memberLamp(m)),
                      const SizedBox(width: 4),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              RappButton.primary(
                key: Key('open-all-${p.id}'),
                label: '全部打开',
                onPressed: null,
              ),
              ConfirmButton(
                key: Key('end-all-${p.id}'),
                label: '全部结束',
                onConfirmed: null,
              ),
              ConfirmButton(
                key: Key('delete-project-${p.id}'),
                label: '删除项目',
                onConfirmed: () => s.deleteProject(p.id),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final m in p.members) ...[
            _MemberRow(state: s, project: p, member: m),
            const SizedBox(height: 6),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: RappButton.secondary(
              key: Key('add-member-${p.id}'),
              label: '添加 app',
              onPressed: () => setState(() => _adding = !_adding),
            ),
          ),
          if (_adding) _AddList(state: s, project: p),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.state,
    required this.project,
    required this.member,
  });
  final MainState state;
  final Project project;
  final Member member;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final s = state;
    final m = member;
    final id = project.id;
    final entry = s.entryFor(m.key);
    final lamp = entry?.lamp ?? Lamp.notOpened;
    final status = s.memberStatus(m);
    final title = '${m.app.name} @ ${s.deviceName(m.app.device)}';
    final verb = openVerb(entry?.lamp);
    final dashed = entry == null;
    final backdrop = rowBackdrop(lamp, t);
    return SizedBox(
      key: Key('member-$id-${m.key}'),
      height: 68,
      child: Semantics(
        container: true,
        label: '$title，$status',
        child: CustomPaint(
          foregroundPainter: dashed ? DashedOutline(t.line, t.r) : null,
          child: Container(
            decoration: dashed
                ? t.panelBox(border: Colors.transparent)
                : t.panelBox(border: rowBorder(lamp, t)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(t.r),
              child: Stack(
                children: [
                  if (backdrop != null)
                    Positioned.fill(child: DecoratedBox(decoration: backdrop)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        ExcludeSemantics(child: StatusLamp(lamp)),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 3,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: t.text,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: t.muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: InlineEdit(
                            key: Key('task-$id-${m.key}'),
                            text: m.task,
                            placeholder: '添加 Agent 任务',
                            semanticLabel: m.task.isEmpty
                                ? '添加 Agent 任务 ${m.app.name}'
                                : '任务 ${m.task}',
                            style: TextStyle(color: t.text, fontSize: 13),
                            onCommit: (v) => s.setTask(id, m.key, v),
                          ),
                        ),
                        const SizedBox(width: 6),
                        RappButton.secondary(
                          key: Key('member-open-$id-${m.key}'),
                          label: verb,
                          semanticLabel: '$verb ${m.app.name}',
                          onPressed: (s.hubUsable && lamp != Lamp.connecting)
                              ? () {
                                  s.openOrSwitch(
                                    m.app.device,
                                    m.app.bundle,
                                    m.app.name,
                                  );
                                  s.closePanel();
                                }
                              : null,
                        ),
                        const SizedBox(width: 6),
                        RappButton.secondary(
                          key: Key('member-remove-$id-${m.key}'),
                          label: '移出',
                          semanticLabel: '移出 ${m.app.name}',
                          onPressed: () => s.removeMember(id, m.key),
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

class _AddList extends StatelessWidget {
  const _AddList({required this.state, required this.project});
  final MainState state;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final apps = state.addableApps(project.id);
    if (apps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '没有可加的 app：先在「设备」里连上一台设备，或设一个常用',
          style: TextStyle(color: t.muted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in apps)
          Builder(
            builder: (context) {
              final label = '${a.name} @ ${state.deviceName(a.device)}';
              return Semantics(
                button: true,
                label: label,
                excludeSemantics: true,
                onTap: () => state.addMember(project.id, a),
                child: InkWell(
                  key: Key('add-${project.id}-${a.key}'),
                  onTap: () => state.addMember(project.id, a),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(label, style: TextStyle(color: t.text)),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
