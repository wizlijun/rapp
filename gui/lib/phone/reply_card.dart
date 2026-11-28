/// The reply area of the phone's focus card (V1c Task 11): allow / deny, numbered options, review points, done.
/// Tokens only. Sends go through [PhoneReplies]; nothing here opens a view.
library;

import 'package:flutter/material.dart';

import '../ui/tokens.dart';
import 'home_model.dart';
import 'hold_button.dart';
import 'phone_voice.dart';
import 'replies.dart';
import 'reply_model.dart';
import 'widgets.dart';

const _hintOptions = '选项都不合适？按住说话，回一句。';
const _sourceAgent = '它自己写的要点 · 点上面的字看全文';
const _sourceRule = '取自计划原文 · 点上面的字看全文';

class ReplyActions extends StatelessWidget {
  const ReplyActions({
    super.key,
    required this.item,
    required this.reply,
    required this.replies,
    this.voice,
    this.onGotIt,
    this.onGoLook,
  });
  final HomeItem item;
  final CardReply reply;
  final PhoneReplies replies;

  /// The hold-to-talk button for [label]; null when there is no microphone or recogniser (V6).
  final Widget Function(String label, ReplyVoiceUse use)? voice;

  /// 「知道了」 of a done card; null disables it.
  final VoidCallback? onGotIt;

  /// 「进去看」 beside a failed outcome.
  final VoidCallback? onGoLook;

  /// The card under the finger: a swap voids a press.
  Object get _arm => (item.id, reply.seq);

  Future<void> _keys(List<String> keys, String word, {bool plan = false}) async {
    final t = reply.target;
    if (t == null) return;
    await replies.keys(item.id, t, reply.seq, keys, doneWord: word);
    final eid = item.pointsEid;
    if (plan && eid != null && replies.outcomeOf(item.id)?.failed != true) replies.markEid(eid);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: replies, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium!;
    final outcome = replies.outcomeOf(item.id);
    final mono = t.monoOf(style.copyWith(color: t.text));
    final children = <Widget>[];

    switch (reply.kind) {
      case ReplyKind.approve:
        if (reply.plain != null) {
          children.add(Text(reply.plain!, style: style.copyWith(color: t.text, fontWeight: FontWeight.w700)));
          children.add(const SizedBox(height: 8));
        }
        if (reply.quote != null) {
          children.add(Text(reply.quote!, style: mono.copyWith(fontSize: style.fontSize), maxLines: 6, overflow: TextOverflow.ellipsis));
          children.add(const SizedBox(height: 12));
        }
        if (reply.risk != null) {
          children.add(_Stripe(word: reply.risk!.word, why: reply.risk!.why));
          children.add(const SizedBox(height: 12));
        }
      case ReplyKind.review:
        final pts = item.points ?? const <String>[];
        for (var i = 0; i < pts.length; i++) {
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 24, child: Text('${i + 1}', style: mono.copyWith(fontSize: style.fontSize))),
              Expanded(child: Text(pts[i], maxLines: 2, overflow: TextOverflow.ellipsis, style: style.copyWith(color: t.text))),
            ]),
          ));
        }
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(item.pointsBy == PointsBy.rule ? _sourceRule : _sourceAgent, style: style.copyWith(color: t.muted)),
        ));
      case ReplyKind.options:
      case ReplyKind.done:
      case ReplyKind.none:
        break;
    }

    if (outcome != null) {
      children.add(_outcome(context, outcome, style, t));
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
    }

    switch (reply.kind) {
      case ReplyKind.approve:
        final deny = reply.deny;
        final allow = reply.allow;
        children.add(_pair(
          deny == null
              ? null
              : PhoneHoldButton(label: '拒绝', armKey: _arm, onSend: () => _keys(deny, '已拒绝')),
          PhoneHoldButton(
            label: '允许',
            armKey: _arm,
            primary: true,
            risky: reply.risk != null,
            onSend: allow == null ? null : () => _keys(allow, '已允许'),
          ),
        ));
      case ReplyKind.options:
        for (var i = 0; i < reply.options.length; i++) {
          if (i > 0) children.add(const SizedBox(height: 12));
          final keys = reply.optionKeys(i);
          children.add(PhoneHoldButton(
            label: reply.options[i],
            armKey: _arm,
            leading: Text('${i + 1}', style: mono.copyWith(fontWeight: FontWeight.w600)),
            onSend: () => _keys(keys, '已回复 ${i + 1}'),
          ));
        }
        if (voice != null) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_hintOptions, style: style.copyWith(color: t.muted)),
          ));
          children.add(const SizedBox(height: 12));
          children.add(voice!('说一句', ReplyVoiceUse.say));
        }
      case ReplyKind.review:
        final ok = reply.planOk;
        children.add(_pair(
          voice?.call('要改', ReplyVoiceUse.revise),
          PhoneHoldButton(
            label: '同意',
            armKey: _arm,
            primary: true,
            onSend: ok == null ? null : () => _keys(ok, '已同意', plan: true),
          ),
        ));
      case ReplyKind.done:
        children.add(_pair(
          voice?.call('说一句', ReplyVoiceUse.say),
          PhoneButton(label: '知道了', primary: true, tall: true, onPressed: onGotIt),
        ));
      case ReplyKind.none:
        break;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _pair(Widget? left, Widget right) => left == null
      ? right
      : IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: left),
            const SizedBox(width: 12),
            Expanded(child: right),
          ]),
        );

  Widget _outcome(BuildContext context, ReplyOutcome o, TextStyle style, RappTokens t) {
    final word = Container(
      constraints: const BoxConstraints(minHeight: phonePrimaryTap),
      alignment: Alignment.centerLeft,
      child: Text(o.word, style: style.copyWith(color: o.failed ? t.warn : t.text, fontWeight: FontWeight.w600)),
    );
    if (!o.failed || onGoLook == null) return word;
    return Row(children: [
      Expanded(child: word),
      const SizedBox(width: 12),
      PhoneButton(label: '进去看', tall: true, onPressed: onGoLook),
    ]);
  }
}

/// The 撤不回 line: a stripe of `warn` at two opacities, a `warn` border, the triangle, the word and the reason.
class _Stripe extends StatelessWidget {
  const _Stripe({required this.word, required this.why});
  final String word, why;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium!;
    return CustomPaint(
      painter: _StripePainter(t.warn),
      child: Container(
        constraints: const BoxConstraints(minHeight: phoneTap),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(border: Border.all(color: t.warn), borderRadius: BorderRadius.circular(t.r)),
        child: Row(children: [
          Text('△', style: style.copyWith(color: t.warn, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text(word, style: style.copyWith(color: t.text, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Expanded(child: Text(why, style: style.copyWith(color: t.text))),
        ]),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  const _StripePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: 0.10));
    final p = Paint()..color = color.withValues(alpha: 0.22);
    const w = 8.0, gap = 16.0;
    for (var x = -size.height; x < size.width; x += w + gap) {
      canvas.drawPath(
        Path()
          ..moveTo(x, size.height)
          ..lineTo(x + w, size.height)
          ..lineTo(x + w + size.height, 0)
          ..lineTo(x + size.height, 0)
          ..close(),
        p,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.color != color;
}
