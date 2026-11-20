// The card of 长语音先让 AI 整理 (spec 2026-11-20-rapp-voice-ai-tidy-design.md §5.3): the voice bubble itself, kept
// where it stood at the release (user 2026-11-20), the AI's words taking the place of the heard ones from the front;
// once they are done a send waits [VoiceTidy.settle], time to click 编辑 or 还原. 编辑 and 直接发送 / 发送 always
// there. Before the first word a shimmer runs over the heard words; a caret follows the AI's (§8.2). A failure
// just takes the card away (the original goes, §8.1 D3). After a send, a hint (if any) shows a while.
import 'package:flutter/material.dart';

import '../ui/controls.dart';
import '../ui/tokens.dart';
import 'voice_overlay.dart' show VoiceBubbleFrame, voiceBubbleTail, voiceTail;
import 'voice_ring.dart' show VoicePick;
import 'voice_tidy.dart';

const _fade = Duration(milliseconds: 160);

class VoiceTidyCard extends StatelessWidget {
  const VoiceTidyCard({super.key, required this.tidy, this.right = true, this.tail = false});

  final VoiceTidy tidy;

  /// The bubble's tail side and whether it has one (iOS's bubble has, the Mac's not).
  final bool right, tail;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: tidy,
        builder: (context, _) => AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : _fade,
          // The card comes in at once (it takes the voice bubble's place); only its going fades.
          switchInCurve: const Threshold(0),
          layoutBuilder: (current, previous) =>
              Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
          child: switch (tidy.phase) {
            TidyPhase.idle => const SizedBox.shrink(key: ValueKey('tidy-idle')),
            TidyPhase.note => _note(context),
            TidyPhase.tidying || TidyPhase.ready => _card(context),
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
    final phase = tidy.phase;
    final editFirst = tidy.pick == VoicePick.edit;
    final ready = phase == TidyPhase.ready;
    final sendLabel = ready ? '发送' : '直接发送';
    final send = editFirst
        ? RappButton.secondary(key: const Key('tidy-send'), label: sendLabel, onPressed: tidy.sendNow)
        : RappButton.primary(key: const Key('tidy-send'), label: sendLabel, onPressed: tidy.sendNow);
    final edit = editFirst
        ? RappButton.primary(key: const Key('tidy-edit'), label: '编辑', onPressed: tidy.editNow)
        : RappButton.secondary(key: const Key('tidy-edit'), label: '编辑', onPressed: tidy.editNow);
    return Column(
      key: const Key('tidy-card'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bubble(context, t),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            edit,
            const SizedBox(width: 8),
            if (ready) ...[
              RappButton.secondary(key: const Key('tidy-restore'), label: '还原', onPressed: tidy.restore),
              const SizedBox(width: 8),
            ],
            send,
          ],
        ),
      ],
    );
  }

  // As the voice bubble: the same fill, padding and type, so the words stay where they were; the footer (where
  // the level bars were) says what the AI is doing.
  Widget _bubble(BuildContext context, RappTokens t) {
    final phase = tidy.phase;
    final (fill, ink, border) =
        tidy.pick == VoicePick.edit ? (t.float.first, t.text, t.text) : (t.text, t.bg, null as Color?);
    final style = TextStyle(color: ink, fontSize: 17, height: 1.35);
    final rest = style.copyWith(color: ink.withValues(alpha: .55));
    final small = TextStyle(color: ink.withValues(alpha: .75), fontSize: 13, height: 20 / 13);
    final status = phase == TidyPhase.ready ? '整理好了，马上发送' : 'AI 整理中…';
    // The AI's words so far, then what is left of the heard ones after as many characters.
    final done = tidy.shown;
    final left = phase == TidyPhase.ready ? '' : String.fromCharCodes(tidy.original.runes.skip(done.runes.length));
    final waiting = phase == TidyPhase.tidying && done.isEmpty;
    final caret = phase == TidyPhase.tidying && done.isNotEmpty;
    return CustomPaint(
      key: const Key('tidy-bubble'),
      painter: VoiceBubbleFrame(
          fill: fill, border: border, dashed: tidy.pick == VoicePick.edit, right: right, radius: t.r, tail: tail),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, tail ? 12 : 16, 16, (tail ? 12 : 16) + (tail ? voiceBubbleTail : 0)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final scaler = MediaQuery.textScalerOf(context);
                // Before the first word the heard words stay readable, a little faint, a shimmer running over them.
                if (waiting) return _Shimmer(child: _body('', left, style, style, c.maxWidth, scaler));
                return _body(done, left, style, rest, c.maxWidth, scaler,
                    caret: caret ? _Caret(color: ink, height: style.fontSize! * 1.1) : null);
              },
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 20,
              child: Row(
                children: [
                  Text(status, key: const Key('tidy-title'), style: small.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (phase == TidyPhase.ready) _Drain(duration: tidy.settle, color: ink),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Up to 4 lines; a longer text shows its last 4, as the voice bubble does.
  Widget _body(String done, String left, TextStyle style, TextStyle rest, double width, TextScaler scaler,
      {Widget? caret}) {
    final all = done + left;
    final tail = voiceTail(all, style, width, scaler);
    final from = tail.length == all.length ? 0 : all.length - (tail.length - 1);
    final lead = from == 0 ? '' : '…';
    final a = from < done.length ? done.substring(from) : '';
    final b = from <= done.length ? left : left.substring(from - done.length);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: lead + a),
        if (caret != null) WidgetSpan(alignment: PlaceholderAlignment.middle, child: caret),
        TextSpan(text: b, style: rest),
      ]),
      key: const Key('tidy-body'),
      style: style,
      maxLines: 4,
    );
  }
}

/// Keeps an animation running while it is shown, still when the system asks for less motion.
mixin _Looping<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  Duration get period;
  late final AnimationController loop = AnimationController(vsync: this, duration: period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      loop
        ..stop()
        ..value = 0;
    } else if (!loop.isAnimating) {
      loop.repeat();
    }
  }

  @override
  void dispose() {
    loop.dispose();
    super.dispose();
  }
}

/// The words a little faint, a brighter band sweeping across them.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});

  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin, _Looping {
  @override
  Duration get period => const Duration(milliseconds: 1400);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        key: const Key('tidy-shimmer'),
        animation: loop,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (b) {
            // At 0 the band is just off the left edge: all faint.
            final band = b.width * .35;
            return const LinearGradient(colors: [Color(0x80FFFFFF), Color(0xFFFFFFFF), Color(0x80FFFFFF)])
                .createShader(Rect.fromLTWH(-band + (b.width + band) * loop.value, 0, band, b.height));
          },
          child: child,
        ),
        child: widget.child,
      );
}

/// A blinking bar after the AI's words.
class _Caret extends StatefulWidget {
  const _Caret({required this.color, required this.height});

  final Color color;
  final double height;

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin, _Looping {
  @override
  Duration get period => const Duration(milliseconds: 1000);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        key: const Key('tidy-caret'),
        animation: loop,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: SizedBox(
            width: 2,
            height: widget.height,
            child: ColoredBox(color: widget.color.withValues(alpha: loop.value < .5 ? 1 : 0)),
          ),
        ),
      );
}

/// The wait before a done send goes: a short bar that empties.
class _Drain extends StatelessWidget {
  const _Drain({required this.duration, required this.color});

  final Duration duration;
  final Color color;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: 0),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration,
        builder: (context, v, _) => SizedBox(
          key: const Key('tidy-drain'),
          width: 66,
          height: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(color: color.withValues(alpha: .25), borderRadius: BorderRadius.circular(2)),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: v,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
}
