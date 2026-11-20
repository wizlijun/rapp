// The card of 长语音先让 AI 整理 (spec 2026-11-20-rapp-voice-ai-tidy-design.md §5.3): what the AI has written so far,
// or why it failed, with 编辑 and 直接发送 always there; after an automatic send, one line that fades.
import 'package:flutter/material.dart';

import '../ui/controls.dart';
import '../ui/tokens.dart';
import 'voice_overlay.dart' show voiceTail;
import 'voice_ring.dart' show VoicePick;
import 'voice_tidy.dart';

const _fade = Duration(milliseconds: 160);

class VoiceTidyCard extends StatelessWidget {
  const VoiceTidyCard({super.key, required this.tidy});

  final VoiceTidy tidy;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: tidy,
        builder: (context, _) => AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : _fade,
          layoutBuilder: (current, previous) =>
              Stack(alignment: Alignment.bottomRight, children: [...previous, ?current]),
          child: switch (tidy.phase) {
            TidyPhase.idle => const SizedBox.shrink(key: ValueKey('tidy-idle')),
            TidyPhase.note => _note(context),
            TidyPhase.tidying || TidyPhase.failed => _card(context),
          },
        ),
      );

  Widget _note(BuildContext context) {
    final t = RappTokens.of(context);
    return DecoratedBox(
      key: const ValueKey('tidy-note-box'),
      decoration: t.floatBox(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(tidy.note ?? '', key: const Key('tidy-note'), style: TextStyle(color: t.muted)),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final t = RappTokens.of(context);
    final failed = tidy.phase == TidyPhase.failed;
    final style = DefaultTextStyle.of(context).style;
    final partial = !failed && tidy.shown.isNotEmpty;
    final body = partial ? tidy.shown : tidy.original;
    final bodyStyle = style.copyWith(color: partial ? t.text : t.muted);
    final editFirst = tidy.pick == VoicePick.edit;
    final send = editFirst
        ? RappButton.secondary(key: const Key('tidy-send'), label: '直接发送', onPressed: tidy.sendOriginal)
        : RappButton.primary(key: const Key('tidy-send'), label: '直接发送', onPressed: tidy.sendOriginal);
    final edit = editFirst
        ? RappButton.primary(key: const Key('tidy-edit'), label: '编辑', onPressed: tidy.editOriginal)
        : RappButton.secondary(key: const Key('tidy-edit'), label: '编辑', onPressed: tidy.editOriginal);
    return DecoratedBox(
      key: const Key('tidy-card'),
      decoration: t.floatBox(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(failed ? 'AI 整理失败' : 'AI 整理中…',
                key: const Key('tidy-title'), style: style.copyWith(fontWeight: FontWeight.w600)),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(tidy.reason ?? '',
                    key: const Key('tidy-reason'), style: style.copyWith(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 4),
            // Up to 4 lines; a longer text shows its last 4, as the voice bubble does.
            LayoutBuilder(
              builder: (context, c) => Text(
                voiceTail(body, bodyStyle, c.maxWidth, MediaQuery.textScalerOf(context)),
                key: const Key('tidy-body'),
                style: bodyStyle,
                maxLines: 4,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [edit, const SizedBox(width: 8), send],
            ),
          ],
        ),
      ),
    );
  }
}
