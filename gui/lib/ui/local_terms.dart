// 本机列「终端」卡片 (overview-local-terms spec §3): the text terminals rapp-term runs on this machine. Only these
// can be opened from other devices at the same time, so 新建 here opens one in the terminal app.
import 'package:flutter/material.dart';

import '../hub_client.dart' show TermRow;
import '../term/term_id.dart' show termDisplayName;
import 'controls.dart' show RappButton;
import 'main_state.dart' show MainState;
import 'session_block.dart' show SessionCard;
import 'term_status.dart' show programWord;
import 'tokens.dart';

class LocalTerms extends StatelessWidget {
  const LocalTerms({super.key, required this.rows, required this.onNew, required this.onFront});
  final List<TermRow> rows;

  /// Null while a 新建 waits: the button is disabled.
  final VoidCallback? onNew;

  /// Brings a row's window to the front; null where that cannot be done (not macOS): the rows are not buttons.
  final void Function(String term)? onFront;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final muted = small?.copyWith(color: t.muted);
    return Column(key: const Key('local-terms'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Expanded(child: Text('终端', style: small?.copyWith(color: t.muted, letterSpacing: t.labelSpacing * t.textSize))),
          RappButton.secondary(key: const Key('local-terms-new'), label: '新建', size: 32, onPressed: onNew),
        ]),
      ),
      if (rows.isEmpty) Text('用 rapp 开的终端，其他设备也能打开', softWrap: true, style: muted),
      for (final (i, r) in rows.indexed) ...[
        if (i > 0) const SizedBox(height: 8),
        _row(r, muted),
      ],
    ]);
  }

  Widget _row(TermRow r, TextStyle? muted) {
    final name = termDisplayName(r.shown, r.host);
    final ps = r.ps;
    final second = ps == null ? '在运行' : programWord(ps);
    final watching = r.attached > 0 ? '${r.attached} 个在看' : null;
    final front = onFront;
    return SessionCard(
      frameKey: Key('local-term-${r.id}'),
      lamp: MainState.localTermLamp(r),
      title: name,
      titleWrap: true,
      second: Text(second, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
      spoken: ['终端 $name', second, ?watching].join('，'),
      trailing: watching == null
          ? null
          : Padding(padding: const EdgeInsets.only(right: 8), child: Text(watching, style: muted)),
      onTap: front == null ? null : () => front(r.id),
    );
  }
}
