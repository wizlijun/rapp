// 「结束终端？」: asked before ending a text terminal whose program in front is not its shell (spec §4.4).
import 'package:flutter/material.dart';

import '../ui/controls.dart';
import '../ui/main_state.dart';

/// Whether to end a terminal running [fg] (null: the device did not name it); false on 取消 or a tap outside.
Future<bool> confirmEndTerm(BuildContext context, String? fg) async =>
    await showDialog<bool>(context: context, builder: (_) => EndTermDialog(fg: fg)) == true;

/// 「结束终端」 of text terminal [key]: asks first when a program is running, then ends it.
Future<void> askEndTerm(BuildContext context, MainState state, String key) =>
    state.endTermAsk(key, confirm: (fg) => context.mounted ? confirmEndTerm(context, fg) : Future.value(false));

class EndTermDialog extends StatefulWidget {
  const EndTermDialog({super.key, this.fg});
  final String? fg;

  @override
  State<EndTermDialog> createState() => _EndTermDialogState();
}

class _EndTermDialogState extends State<EndTermDialog> {
  // The focus starts on 取消: Return keeps the terminal.
  final _cancel = FocusNode(debugLabel: 'end-term-cancel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cancel.requestFocus();
    });
  }

  @override
  void dispose() {
    _cancel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('结束终端？'),
        content: Text('里面还在跑${widget.fg == null ? '程序' : ' ${widget.fg}'}，结束后它也会被关掉。'),
        actions: [
          RappButton.quiet(
            key: const Key('end-term-cancel'),
            label: '取消',
            focusNode: _cancel,
            onPressed: () => Navigator.pop(context, false),
          ),
          RappButton.danger(
            key: const Key('end-term-ok'),
            label: '结束',
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      );
}
