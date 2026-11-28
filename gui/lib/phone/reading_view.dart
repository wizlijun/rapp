/// The phone's reading view (V1c Task 13): the terminal's current screen, reflowed into blocks that fit a narrow
/// screen. One column; only the current screen (scrollback is not shown). Tokens only.
library;

import 'package:flutter/material.dart';

import '../term/reflow.dart';
import '../term/term_model.dart';
import '../ui/tokens.dart';

const double _inset = 16;

class PhoneReadingView extends StatelessWidget {
  const PhoneReadingView({super.key, required this.model});
  final TermModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: model, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final t = RappTokens.of(context);
    final body = Theme.of(context).textTheme.bodyMedium!.copyWith(color: t.text);
    final blocks = reflowLines(model.screen, wrapped: model.wrapped, cols: model.cols, screenFrom: 0);
    // reverse: the newest block sits at the bottom edge and the list grows upward.
    return ListView(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: _inset, vertical: 12),
      children: [
        for (final b in blocks.reversed)
          Padding(padding: const EdgeInsets.only(top: 12), child: _block(b, t, body)),
      ],
    );
  }

  Widget _block(ReadBlock b, RappTokens t, TextStyle body) {
    switch (b.kind) {
      case ReadKind.raw:
      case ReadKind.tool:
        final style = t.monoOf(body.copyWith(color: b.kind == ReadKind.tool ? t.muted : t.text, fontSize: 13));
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(b.text, style: style, softWrap: false),
        );
      case ReadKind.heading:
        return Text(b.text, style: body.copyWith(fontWeight: FontWeight.w700, fontSize: (body.fontSize ?? 14) + 2));
      case ReadKind.meta:
        return Text(b.text, style: body.copyWith(color: t.muted, fontSize: 13));
      case ReadKind.prose:
        return Text(b.text, style: body);
    }
  }
}
