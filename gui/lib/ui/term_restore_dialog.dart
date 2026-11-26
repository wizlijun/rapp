// 「恢复上次的终端」: the list of saved text terminals a device can reopen (spec 2026-11-26 §4.6). It shows the name,
// the program and how long ago, never a directory (the device does not even send one).
import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'controls.dart';
import 'main_state.dart';

/// 「刚才」 under a minute, then 「N 分钟前」, 「N 小时前」, 「N 天前」.
String agoWords(Duration d) {
  if (d.inMinutes < 1) return '刚才';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  return '${d.inDays} 天前';
}

/// What the dialog was closed with.
sealed class TermRestoreChoice {
  const TermRestoreChoice();
}

class RestoreKeys extends TermRestoreChoice {
  const RestoreKeys(this.keys);
  final List<String> keys;
}

class ForgetKeys extends TermRestoreChoice {
  const ForgetKeys(this.keys);
  final List<String> keys;
}

class NewTerm extends TermRestoreChoice {
  const NewTerm();
}

/// Asks which of [device]'s saved terminals to reopen, then does it: 恢复所选 restores the ticked ones, 全部清掉
/// forgets every listed one, 新建 makes a new terminal the way the 常用 · 终端 tile does.
Future<void> showTermRestore(BuildContext context, MainState state, String device) async {
  final saved = state.savedTerms(device);
  if (saved.isEmpty) return;
  final choice = await showDialog<TermRestoreChoice>(
    context: context,
    builder: (_) => TermRestoreDialog(deviceName: state.deviceName(device), saved: saved, now: DateTime.now()),
  );
  switch (choice) {
    case RestoreKeys(:final keys):
      await state.restoreSaved(device, keys);
    case ForgetKeys(:final keys):
      await state.forgetSaved(device, keys);
    case NewTerm():
      await state.newTermFromRestore(device);
    case null:
      break;
  }
}

class TermRestoreDialog extends StatefulWidget {
  const TermRestoreDialog({super.key, required this.deviceName, required this.saved, required this.now});
  final String deviceName;
  final List<TermSaved> saved;
  final DateTime now;

  @override
  State<TermRestoreDialog> createState() => _TermRestoreDialogState();
}

class _TermRestoreDialogState extends State<TermRestoreDialog> {
  // Saved before the machine last started: ticked; the rest not.
  late final Set<String> _ticked = {for (final s in widget.saved) if (s.boot) s.key};

  String _row(TermSaved s) {
    final ago = widget.now.difference(DateTime.fromMillisecondsSinceEpoch(s.saved * 1000));
    return '${s.name}  ${s.prog ?? '—'}  ${agoWords(ago.isNegative ? Duration.zero : ago)}';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('恢复上次的终端 · ${widget.deviceName}'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final s in widget.saved)
                RappCheckRow(
                  key: Key('restore-row-${s.key}'),
                  label: _row(s),
                  value: _ticked.contains(s.key),
                  onChanged: (v) => setState(() => v ? _ticked.add(s.key) : _ticked.remove(s.key)),
                ),
            ]),
          ),
        ),
        actions: [
          RappButton.secondary(
            key: const Key('restore-forget'),
            label: '全部清掉',
            onPressed: () => Navigator.pop(context, ForgetKeys([for (final s in widget.saved) s.key])),
          ),
          RappButton.secondary(key: const Key('restore-new'), label: '新建', onPressed: () => Navigator.pop(context, const NewTerm())),
          RappButton.secondary(key: const Key('restore-cancel'), label: '取消', onPressed: () => Navigator.pop(context)),
          RappButton.primary(
            key: const Key('restore-ok'),
            label: '恢复所选',
            onPressed: _ticked.isEmpty
                ? null
                : () => Navigator.pop(context, RestoreKeys([for (final s in widget.saved) if (_ticked.contains(s.key)) s.key])),
          ),
        ],
      );
}
