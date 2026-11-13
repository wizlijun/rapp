// 本机 › 版本与升级 (spec §5): one line, its buttons, 自动升级 and 回到上一版. No accent colour:
// an update never asks for attention (design language §0, §1 rule 1).
import 'package:flutter/material.dart';

import '../service_client.dart';
import '../ui/controls.dart';
import '../ui/tokens.dart';
import '../update.dart';

const _labels = {
  UpdateAction.check: '检查更新',
  UpdateAction.apply: '立即升级',
  UpdateAction.applyAnyway: '仍然安装',
  UpdateAction.dismiss: '这一版先不装',
  UpdateAction.openPage: '打开安装包',
};

class UpdateSection extends StatefulWidget {
  const UpdateSection({
    super.key,
    required this.info,
    required this.onCheck,
    required this.onApply,
    required this.onDismiss,
    required this.onRollback,
    required this.onSetAuto,
    required this.onOpenPage,
  });

  final UpdateInfo info;
  final Future<void> Function() onCheck;

  /// [confirm]: the user accepted the signature change (「仍然安装」).
  final Future<void> Function(bool confirm) onApply;
  final Future<void> Function(String version) onDismiss;
  final Future<void> Function() onRollback;
  final Future<void> Function(bool) onSetAuto;
  final void Function(String url) onOpenPage;

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  bool _busy = false;

  /// The last failed call: its error, and its installer page when it has one.
  ServiceException? _failure;

  UpdateInfo get u => widget.info;

  @override
  void didUpdateWidget(UpdateSection old) {
    super.didUpdateWidget(old);
    // A new state answers the old error.
    if (old.info.state != u.state) _failure = null;
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await f();
    } on ServiceException catch (e) {
      _failure = e;
    } catch (e) {
      _failure = ServiceException('$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  VoidCallback? _action(UpdateAction a) {
    if (_busy) return null;
    final v = u.latest;
    return switch (a) {
      UpdateAction.check => () => _run(widget.onCheck),
      UpdateAction.apply => () => _run(() => widget.onApply(false)),
      UpdateAction.applyAnyway => () => _run(() => widget.onApply(true)),
      UpdateAction.dismiss => v == null ? null : () => _run(() => widget.onDismiss(v)),
      UpdateAction.openPage => u.page == null ? null : () => widget.onOpenPage(u.page!),
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final view = updateView(u);
    final notes = u.notes ?? '';
    final failure = _failure;
    final page = failure?.page;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('版本与升级', style: TextStyle(color: t.text, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(view.line, style: TextStyle(color: t.text)),
        for (final a in view.actions)
          RappButton.secondary(key: Key('update-${a.name}'), label: _labels[a]!, onPressed: _action(a)),
      ]),
      if (u.state == 'ready' && notes.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(notes, style: TextStyle(color: t.muted, fontSize: 12)),
        ),
      if (failure != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(failure.message, style: TextStyle(color: t.text)),
            if (page != null && !view.actions.contains(UpdateAction.openPage))
              RappButton.secondary(label: _labels[UpdateAction.openPage]!, onPressed: () => widget.onOpenPage(page)),
          ]),
        ),
      if (u.state != 'off')
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          MergeSemantics(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('自动升级', style: TextStyle(color: t.text)),
              Switch(
                value: u.autoUpdate,
                onChanged: _busy ? null : (v) => _run(() => widget.onSetAuto(v)),
              ),
            ]),
          ),
          if (u.canRollback)
            ConfirmButton(label: '回到上一版', onConfirmed: _busy ? null : () => _run(widget.onRollback)),
        ]),
    ]);
  }
}
