// The card of 长语音先让 AI 整理 (spec 2026-11-20-rapp-voice-ai-tidy-design.md §5.3): the voice bubble itself, kept
// where it stood at the release (user 2026-11-20), the AI's words taking the place of the heard ones from the front;
// once they are done a send waits [VoiceTidy.settle], time to click 编辑 or 还原. 编辑 and 直接发送 / 发送 always
// there. Before the first word a shimmer runs over the heard words; a caret follows the AI's (§8.2). A failure
// just takes the card away (the original goes, §8.1 D3). After a send, a hint (if any) shows a while.
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;

import '../ui/controls.dart';
import '../ui/tokens.dart';
import 'voice_overlay.dart' show VoiceBubbleFrame, voiceBubbleTail, voiceTail;
import 'voice_ring.dart' show VoicePick;
import 'tidy_diff.dart';
import 'tidy_mode.dart';
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
        builder: (context, _) {
          final offer = tidy.offer;
          // An offer in the bubble is drawn by the bubble; with no card (or one not on screen) it is a box.
          final box = offer != null && !(offer.inBubble && _showsBubble);
          final stand = AnimatedSwitcher(
            key: const ValueKey('tidy-stand'),
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
          );
          // One shape always, so the card (its countdown, shimmer, caret) keeps its State while the box comes and goes;
          // the box stands above the card (or alone).
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: right ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (box) _Appear(key: const ValueKey('learn-box'), child: _offerBox(context, offer)),
              if (box && (_showsBubble || tidy.phase == TidyPhase.note)) const SizedBox(height: 8),
              stand,
            ],
          );
        },
      );

  bool get _showsBubble => tidy.phase == TidyPhase.tidying || tidy.phase == TidyPhase.ready;

  // The small box to remember what the AI changed (or what was flipped back); 8 s, [VoiceTidy.offerLife].
  Widget _offerBox(BuildContext context, LearnOffer o) {
    final t = RappTokens.of(context);
    final small = TextStyle(color: t.text, fontSize: 13, height: 20 / 13);
    return DecoratedBox(
      key: const Key('learn-offer'),
      decoration: t.floatBox(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(o.done ? '已记住' : '记住这个改法？',
                  key: o.done ? const Key('learn-done') : null,
                  style: small.copyWith(fontWeight: FontWeight.w600)),
              if (!o.done) ...[
                for (var i = 0; i < o.items.length; i++)
                  InkWell(
                    onTap: () => tidy.togglePick(i),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          key: Key('learn-item-$i'),
                          value: o.picked.contains(i),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (_) => tidy.togglePick(i),
                        ),
                        Flexible(child: Text(o.items[i].label, style: small, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RappButton.secondary(key: const Key('learn-ignore'), label: '忽略', onPressed: tidy.dismissOffer),
                    const SizedBox(width: 8),
                    RappButton.primary(key: const Key('learn-remember'), label: '记住', onPressed: tidy.remember),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // The same question in the bubble, one line under the words: only for a flipped word ("别把「X」改成「Y」").
  Widget _offerLine(LearnOffer o, TextStyle small, Color ink) {
    final it = o.items.first;
    return _Appear(
      key: const ValueKey('learn-line'),
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          key: const Key('learn-offer'),
          children: [
            Expanded(
              child: o.done
                  ? Text('已记住', key: const Key('learn-done'), style: small.copyWith(fontWeight: FontWeight.w600))
                  : Text('记住：别把「${it.observed}」改成「${it.avoid}」？',
                      style: small, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            if (!o.done) ...[
              _LineAction(key: const Key('learn-ignore'), label: '忽略', color: ink.withValues(alpha: .75), onTap: tidy.dismissOffer),
              _LineAction(key: const Key('learn-remember'), label: '记住', color: ink, onTap: tidy.remember, bold: true),
            ],
          ],
        ),
      ),
    );
  }

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
    // Done, and the last of its words is out: a send's wait starts now ([VoiceTidy.settle]).
    final ready = phase == TidyPhase.ready && !tidy.writing;
    final held = tidy.comparing || tidy.stopped;
    final status = !ready ? 'AI 整理中…' : (held ? '整理好了' : '整理好了，马上发送');
    // Before the first word the heard words are the body; then the AI's take it, the heard ones kept under them
    // in one faint line to compare (user 2026-11-20), the whole of them on a tap.
    final done = tidy.shown;
    final waiting = phase == TidyPhase.tidying && done.isEmpty;
    // The words are all out: the changes can be marked, and flipped.
    final marked = ready;
    final caret = (phase == TidyPhase.tidying && done.isNotEmpty) || tidy.writing;
    return _TapZone(builder: (bodyKey) => CustomPaint(
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
                if (waiting) {
                  return _Shimmer(child: _TidyBody(tidy: tidy, done: '', left: tidy.original, style: style, rest: style, width: c.maxWidth, scaler: scaler, ink: ink));
                }
                return _TidyBody(
                    key: bodyKey,
                    tidy: tidy,
                    done: marked ? tidy.text : done,
                    left: '',
                    style: style,
                    rest: rest,
                    width: c.maxWidth,
                    scaler: scaler,
                    ink: ink,
                    marks: marked,
                    caret: caret ? _Caret(color: ink, height: style.fontSize! * 1.1) : null);
              },
            ),
            if (!waiting) ...[
              const SizedBox(height: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: tidy.compare,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '原话 · ', style: small.copyWith(fontWeight: FontWeight.w600)),
                    TextSpan(text: tidy.original),
                  ]),
                  key: const Key('tidy-original'),
                  style: small.copyWith(color: ink.withValues(alpha: .55)),
                  maxLines: tidy.comparing ? 8 : 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (tidy.offer case final o? when o.inBubble) _offerLine(o, small, ink),
            const SizedBox(height: 8),
            SizedBox(
              height: 20,
              child: Row(
                children: [
                  Text(status, key: const Key('tidy-title'), style: small.copyWith(fontWeight: FontWeight.w600)),
                  if (tidy.setMode != null && tidy.canSwitch) const SizedBox(width: 4),
                  if (tidy.setMode != null && tidy.canSwitch)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: tidy.switchMode,
                      child: Text('· ${tidy.running.label} ⇄',
                          key: const Key('tidy-mode'), style: small.copyWith(fontWeight: FontWeight.w600)),
                    ),
                  const Spacer(),
                  if (ready && !held) _Drain(duration: tidy.settle, color: ink),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
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

/// Fades in over [_fade]; at once with reduced motion.
class _Appear extends StatelessWidget {
  const _Appear({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : _fade,
        builder: (context, v, child) => Opacity(opacity: v, child: child),
        child: child,
      );
}

/// A text action on the bubble's offer line, with room enough to hit.
class _LineAction extends StatelessWidget {
  const _LineAction({super.key, required this.label, required this.color, required this.onTap, this.bold = false});

  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool bold;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(label,
              style: TextStyle(color: color, fontSize: 13, height: 20 / 13, fontWeight: bold ? FontWeight.w600 : null)),
        ),
      );
}

/// The body: up to 4 lines, a longer text shows its last 4 as the voice bubble does. With [marks], each of the
/// AI's changes that is still in view is underlined dashed and a tap on it (or near it) flips it.
///
/// The text is [done] (rune offsets of [VoiceTidy.changes] shifted for each flip before them, [_ranges]) and then
/// [left]. A tap is not a `TapGestureRecognizer` on the span: a word is a few pixels wide, so the whole bubble ([_TapZone])
/// takes the tap and asks the paragraph where each mark is, widened (6 px each side; at least 44 px tall on iOS, 24
/// elsewhere), the nearest centre wins.
/// The bubble's tap: the padding around the words is part of it, so a tap just above a line still reaches a mark.
class _TapZone extends StatefulWidget {
  const _TapZone({required this.builder});

  final Widget Function(Key bodyKey) builder;

  @override
  State<_TapZone> createState() => _TapZoneState();
}

class _TapZoneState extends State<_TapZone> {
  final _body = GlobalKey<_TidyBodyState>();

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapUp: (d) => _body.currentState?.tap(d.globalPosition),
        child: widget.builder(_body),
      );
}

class _TidyBody extends StatefulWidget {
  const _TidyBody({
    super.key,
    required this.tidy,
    required this.done,
    required this.left,
    required this.style,
    required this.rest,
    required this.width,
    required this.scaler,
    required this.ink,
    this.marks = false,
    this.caret,
  });

  final VoiceTidy tidy;
  final String done, left;
  final TextStyle style, rest;
  final double width;
  final TextScaler scaler;
  final Color ink;
  final bool marks;
  final Widget? caret;

  @override
  State<_TidyBody> createState() => _TidyBodyState();
}

class _TidyBodyState extends State<_TidyBody> {
  final _key = GlobalKey();
  // What is marked right now: the change's index and its UTF-16 range in the paragraph's text.
  var _marked = <(int, int, int)>[];

  /// Each change's rune range in the current text: the later ones shift by what the flips before them changed.
  static List<(int, int)> ranges(List<TidyChange> changes, bool Function(int) flipped) {
    final out = <(int, int)>[];
    var shift = 0;
    for (var i = 0; i < changes.length; i++) {
      final c = changes[i];
      final start = c.start + shift;
      final len = flipped(i) ? c.before.runes.length : c.end - c.start;
      out.add((start, start + len));
      shift += len - (c.end - c.start);
    }
    return out;
  }

  RenderParagraph? _paragraph() {
    RenderParagraph? find(RenderObject r) {
      if (r is RenderParagraph) return r;
      RenderParagraph? out;
      r.visitChildren((c) => out ??= find(c));
      return out;
    }

    final ro = _key.currentContext?.findRenderObject();
    return ro == null ? null : find(ro);
  }

  /// A tap at [global] flips the nearest mark within reach, if any.
  void tap(Offset global) {
    final para = _paragraph();
    if (para == null || !para.attached) return;
    final p = para.globalToLocal(global);
    final minH = defaultTargetPlatform == TargetPlatform.iOS ? 44.0 : 24.0;
    int? best;
    var bestD = double.infinity;
    for (final (i, a, b) in _marked) {
      for (final box in para.getBoxesForSelection(TextSelection(baseOffset: a, extentOffset: b))) {
        var r = box.toRect();
        r = Rect.fromLTRB(r.left - 6, r.top, r.right + 6, r.bottom);
        if (r.height < minH) r = Rect.fromCenter(center: r.center, width: r.width, height: minH);
        if (!r.contains(p)) continue;
        final d = (r.center - p).distanceSquared;
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
    }
    if (best != null) widget.tidy.flip(best);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final all = w.done + w.left;
    final tail = voiceTail(all, w.style, w.width, w.scaler);
    final cut = tail.length != all.length;
    final from = cut ? all.length - (tail.length - 1) : 0; // UTF-16 index in [all]
    final fromRune = all.substring(0, from).runes.length;
    final runes = all.runes.toList();
    final doneRunes = w.done.runes.length;
    final lead = cut ? '…' : '';
    final children = <InlineSpan>[];
    final marked = <(int, int, int)>[];
    var len = lead.length; // UTF-16 length of the plain text built so far
    var at = fromRune; // rune offset of what has been emitted
    String run(int a, int b) => String.fromCharCodes(runes.sublist(a, b));
    void plain(int upto) {
      // Until [upto], the part in [done] plain, the part in [left] faint.
      final mid = upto < doneRunes ? upto : doneRunes;
      if (mid > at) {
        final t = run(at, mid);
        children.add(TextSpan(text: (children.isEmpty ? lead : '') + t));
        len += t.length;
        at = mid;
      }
    }

    if (w.marks) {
      final rs = ranges(w.tidy.changes, w.tidy.flipped);
      for (var i = 0; i < rs.length; i++) {
        final (a, b) = rs[i];
        // A change cut off by the tail (or only partly in view) is not marked.
        if (a < fromRune || b > doneRunes || a >= b) continue;
        plain(a);
        final t = run(a, b);
        if (children.isEmpty && lead.isNotEmpty) children.add(TextSpan(text: lead));
        children.add(TextSpan(
          text: t,
          style: TextStyle(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dashed,
            decorationColor: w.ink,
          ),
        ));
        marked.add((i, len, len + t.length));
        len += t.length;
        at = b;
      }
    }
    plain(doneRunes);
    if (children.isEmpty && lead.isNotEmpty) children.add(TextSpan(text: lead));
    if (w.caret != null) children.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: w.caret!));
    if (w.left.isNotEmpty || w.done.isEmpty) {
      final b = run(at > doneRunes ? at : doneRunes, runes.length);
      children.add(TextSpan(text: b, style: w.rest));
    }
    _marked = marked;
    final text = Text.rich(
      TextSpan(children: children),
      key: const Key('tidy-body'),
      style: w.style,
      maxLines: 4,
    );
    return KeyedSubtree(key: _key, child: text);
  }
}
