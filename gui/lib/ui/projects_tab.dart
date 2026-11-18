// 项目 tab of the side panel (S5 K17): named groups of apps, each with an
// optional note, a lamp per member, and open/switch per member.
import 'package:flutter/material.dart';

import 'controls.dart';
import 'inline_edit.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'projects.dart';
import 'session_model.dart';
import 'tokens.dart';
import 'workspace_store.dart';

class ProjectsTab extends StatefulWidget {
  const ProjectsTab({super.key, required this.state});
  final MainState state;

  @override
  State<ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<ProjectsTab> {
  final _cards = <String, GlobalKey>{};

  MainState get state => widget.state;

  void _focus() {
    final id = state.focusProject;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _cards[id]?.currentContext;
      if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx, alignment: 0);
      if (state.focusProject == id) state.focusProject = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final t = RappTokens.of(context);
        final projects = orderedProjects(state.projects);
        final undo = state.undoableDelete;
        _focus();
        return SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _NewProject(state: state),
            const SizedBox(height: 10),
            if (undo != null) ...[
              Row(children: [
                Expanded(
                  child: Text('已删除「$undo」', style: TextStyle(color: t.muted)),
                ),
                RappButton.secondary(
                  key: const Key('undo-delete'),
                  label: '撤销',
                  onPressed: state.undoDelete,
                ),
              ]),
              const SizedBox(height: 10),
            ],
            for (final p in projects) ...[
              KeyedSubtree(
                key: _cards.putIfAbsent(p.id, GlobalKey.new),
                child: _ProjectCard(
                  key: Key('project-${p.id}'),
                  state: state,
                  project: p,
                ),
              ),
              const SizedBox(height: 10),
            ],
          ]),
        );
      },
    );
  }
}

/// The top row: one input shared by 新建项目 and 存成项目 (so they can never both be open),
/// and the 存成项目 button, which turns the input into "name the open sessions".
class _NewProject extends StatefulWidget {
  const _NewProject({required this.state});
  final MainState state;

  @override
  State<_NewProject> createState() => _NewProjectState();
}

class _NewProjectState extends State<_NewProject> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  bool _saveOpen = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // Leaving an empty field drops save mode; a typed name keeps it.
      if (!_focus.hasFocus && _c.text.isEmpty && _saveOpen) {
        setState(() => _saveOpen = false);
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String v) {
    final made = _saveOpen && widget.state.canSaveOpenAsProject
        ? widget.state.saveOpenAsProject(v)
        : widget.state.createProject(v);
    if (made != null) {
      _c.clear();
      setState(() => _saveOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final can = widget.state.canSaveOpenAsProject;
    if (_saveOpen && !can) _saveOpen = false; // nothing left to save
    return Row(children: [
      Expanded(
        child: TextField(
          key: const Key('new-project'),
          controller: _c,
          focusNode: _focus,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: _saveOpen ? '存成项目' : '新建项目',
          ),
          onSubmitted: _submit,
        ),
      ),
      if (_saveOpen) ...[
        const SizedBox(width: 6),
        RappButton.secondary(
          key: const Key('new-mode'),
          label: '新建项目',
          onPressed: () => setState(() => _saveOpen = false),
        ),
      ],
      const SizedBox(width: 6),
      RappButton.secondary(
        key: const Key('save-open'),
        label: '存成项目',
        onPressed: can
            ? () {
                setState(() => _saveOpen = true);
                _focus.requestFocus();
              }
            : null,
      ),
    ]);
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
    final current = s.currentProject == p.id;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: current
          ? t.panelBox().copyWith(border: Border.all(color: t.text, width: 2))
          : t.panelBox(border: t.line),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(builder: (context, row) => Row(
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
              // Many members on a narrow card: the lamps wrap within a part of the row, so the
              // name and the buttons keep their room.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: row.maxWidth * 0.25),
                child: ExcludeSemantics(
                  child: Wrap(
                    key: Key('project-lamps-${p.id}'),
                    spacing: 4,
                    runSpacing: 4,
                    children: [for (final m in p.members) StatusLamp(s.memberLamp(m))],
                  ),
                ),
              ),
              // 切到 and 固定 belong to the title row (project spec §14); the name gives way.
              const SizedBox(width: 8),
              RappButton.secondary(
                key: Key('switch-${p.id}'),
                label: '切到',
                semanticLabel: '切到 ${p.name}',
                onPressed: () => s.switchProject(p.id),
              ),
              const SizedBox(width: 6),
              RappButton.secondary(
                key: Key('pin-${p.id}'),
                label: p.pinned ? '取消固定' : '固定',
                semanticLabel: '${p.pinned ? '取消固定' : '固定'} ${p.name}',
                onPressed: () => s.togglePinned(p.id),
              ),
            ],
          )),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              RappButton.primary(
                key: Key('open-all-${p.id}'),
                label: '全部打开',
                onPressed: s.hubUsable && p.members.isNotEmpty
                    ? () => s.openAll(p.id)
                    : null,
              ),
              ConfirmButton(
                key: Key('end-all-${p.id}'),
                label: '全部结束',
                onConfirmed: p.members.any((m) => s.entryFor(m.key) != null)
                    ? () => s.endAll(p.id)
                    : null,
              ),
              RappButton.secondary(
                key: Key('delete-project-${p.id}'),
                label: '删除项目',
                onPressed: () => s.deleteProject(p.id),
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
    final title = '${s.labelOf(m.app)} @ ${s.deviceName(m.app.device)}';
    final verb = openVerb(entry?.lamp, takenOver: entry?.takenOver ?? false);
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
                                style: TextStyle(color: t.muted),
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
                            placeholder: '备注',
                            semanticLabel: m.task.isEmpty
                                ? '备注 ${s.labelOf(m.app)}'
                                : '备注 ${m.task}',
                            style: TextStyle(color: t.text),
                            onCommit: (v) => s.setTask(id, m.key, v),
                          ),
                        ),
                        const SizedBox(width: 6),
                        RappButton.secondary(
                          key: Key('member-open-$id-${m.key}'),
                          label: verb,
                          semanticLabel: '$verb ${s.labelOf(m.app)}',
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
                          semanticLabel: '移出 ${s.labelOf(m.app)}',
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
              final label = '${state.labelOf(a)} @ ${state.deviceName(a.device)}';
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
