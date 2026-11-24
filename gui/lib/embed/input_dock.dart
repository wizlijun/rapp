// The input dock (input-dock spec §4–§5), on every platform: one floating block per session over the stage — the
// writing panel (the text area) on top, 8, the 快捷区 (the key bar) at the bottom — standing on its anchor, and the
// stage's button stack. The picture under it never moves. The text area and the 快捷区 come and go by their own
// controllers, each folding into the block's bottom; the soft keyboard is followed live, frame by frame.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../term/term_session_port.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'app_profile.dart' show InputPoint, defaultComposerAt;
import 'composer_float.dart' show FloatingComposer, composerNoDrag;
import 'key_bar.dart';
import 'panel_place.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'stage_buttons.dart';

/// A move the dock makes itself: the text area or the 快捷区 coming or going, the stack between its places.
const dockMove = Duration(milliseconds: 340);
const _curve = Curves.easeOutCubic;

/// A closing text area fades out over its last this long; an opening one fades in as it comes up.
const _fadeOut = Duration(milliseconds: 100);

// The eased "shown" at which a close from fully open has [_fadeOut] left.
final _fadeFrom = 1 - _curve.transform(1 - _fadeOut.inMicroseconds / dockMove.inMicroseconds);

/// The stack's bottom with no block under it: [stageButtonsUp], or [stageButtonsEdge] above a soft keyboard.
double restStackBottom(double keyboard) => math.max(stageButtonsUp, keyboard > 0 ? keyboard + stageButtonsEdge : 0);

/// The stack's bottom up off the stage's bottom: 8 above the [block] (stage coordinates) while it has a height, never
/// under [restStackBottom], and never so high that a stack [stackHeight] tall leaves the stage's top 8.
double stackBottomOf({required Size stage, required Rect? block, required double keyboard, required double stackHeight}) {
  final rest = restStackBottom(keyboard);
  if (block == null || block.height == 0) return rest;
  return math.max(rest, math.min(stage.height - block.top + 8, stage.height - 8 - stackHeight));
}

/// Whether the stack lies in a row: on a portrait stage, and also when its column [columnHeight] tall has no room
/// between the block's top (8 above it, as [stackBottomOf] puts it) and the stage's top 8 — iPhone landscape with a
/// tall 快捷区, where [stackBottomOf] would otherwise pull the column down over the keys.
bool stackUprightOf({required Size stage, required Rect? block, required double keyboard, required double columnHeight}) {
  if (stage.height > stage.width) return true;
  final rest = restStackBottom(keyboard);
  final bottom = block == null || block.height == 0 ? rest : math.max(rest, stage.height - block.top + 8);
  return bottom + columnHeight > stage.height - 8;
}

/// Off iOS, the block's default anchor: bottom centre, clear of the corner row of controls [rowHeight] tall.
InputPoint desktopComposerAt(double rowHeight) => InputPoint(0.5, rowHeight + 20, fromBottom: true);

/// The open stack's height: 语音 and 收起 in one row, one above the other, or 收起 alone.
double openStackHeight(bool upright, bool voice) => upright || !voice ? stageButtonSize : 2 * stageButtonSize + 12;

/// The closed stack's height: its [buttons] one above the other, or side by side in one row when [upright].
double closedStackHeight({required int buttons, required bool upright}) =>
    buttons == 0 ? 0 : upright ? stageButtonSize : buttons * stageButtonSize + (buttons - 1) * 12;

/// The stack's height as a column: open ([openStackHeight]) or closed with its [buttons] ([closedStackHeight]).
double stackColumnHeight({required bool open, required int buttons, required bool voice}) =>
    open ? openStackHeight(false, voice) : closedStackHeight(buttons: buttons, upright: false);

/// How many buttons the stack holds with the text area closed: 语音 (when [voice]), 输入 and the 快捷区 toggle, and
/// 还原 while zoomed.
int stackButtonCount(RemoteSession s, {required bool voice}) {
  final button = s.composerAllowed;
  return (button && voice ? 1 : 0) + (button ? 2 : 0) + (s.currentZoomed ? 1 : 0);
}

/// Lays out a session's input dock over the whole stage: the block in a [FloatingComposer] at the session's place
/// (the [text] area over the [KeyBar], 8 between), and the [stack] 8 above the block's top ([stackBottomOf]).
///
/// The text area stays while it goes: it folds down into the block's bottom in [dockMove] and fades out over the
/// last 100 ms; opened again before that is over, the same panel comes back from the height and the opacity it had.
/// The 快捷区 follows [quickHidden] the same way. With both folded nothing stands where the block was: the 快捷区
/// toggle waits in the [stack], beside 输入.
class InputDock extends StatefulWidget {
  const InputDock(
      {super.key,
      required this.state,
      required this.session,
      required this.port,
      required this.keyboard,
      required this.listenable,
      required this.voice,
      required this.text,
      required this.stack});

  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  /// How far the soft keyboard reaches up over the stage's bottom.
  final double keyboard;

  /// What [text] and [stack] are built from, beyond the session's panel.
  final Listenable listenable;

  /// The stack has 语音 (it stands higher in a column).
  final bool voice;

  /// The writing panel, at most [maxHeight] tall.
  final Widget Function(BuildContext context, double maxHeight) text;

  /// The button stack, its bottom [bottom] up off the [stage]'s bottom.
  final Widget Function(BuildContext context, double bottom, Size stage, bool upright) stack;

  @override
  State<InputDock> createState() => InputDockState();
}

class InputDockState extends State<InputDock> with TickerProviderStateMixin {
  late bool _open = _wanted;
  late bool _hidden = _quickHidden;
  late final AnimationController _shown = AnimationController(vsync: this, duration: dockMove, value: _open ? 1 : 0);
  late final AnimationController _quick = AnimationController(vsync: this, duration: dockMove, value: _hidden ? 0 : 1);

  // The text area's opacity is a line in "shown" through (_fadeV, _fadeO), clamped to 0..1. A close from open is
  // opaque down to [_fadeFrom], then goes to 0 with it; an open goes from where it is to 1 with "shown" at 1. A turn
  // mid-move starts the new line from the opacity it had, so it never snaps.
  double _fadeV = 0, _fadeO = 0, _fadeSlope = 1 / _fadeFrom;
  bool _reduced = false;

  bool get _wanted => widget.session.composer.open && widget.session.composerAllowed;
  bool get _quickHidden => quickHidden(widget.state, widget.session);

  @override
  void initState() {
    super.initState();
    _listen(widget);
  }

  @override
  void didUpdateWidget(InputDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session && oldWidget.state == widget.state) return;
    _unlisten(oldWidget);
    _listen(widget);
    _changed();
    _quickChanged();
  }

  void _listen(InputDock w) {
    w.session.addListener(_changed);
    w.session.composer.addListener(_changed);
    w.state.addListener(_quickChanged);
  }

  void _unlisten(InputDock w) {
    w.session.removeListener(_changed);
    w.session.composer.removeListener(_changed);
    w.state.removeListener(_quickChanged);
  }

  @override
  void dispose() {
    _unlisten(widget);
    _shown.dispose();
    _quick.dispose();
    super.dispose();
  }

  void _changed() {
    final open = _wanted;
    if (open == _open) return;
    _open = open;
    final c = widget.session.composer;
    final v = _shown.value;
    final o = _opacity(v);
    if (open) {
      // Back before the close was over: the panel is the one still there, so it takes the caret itself.
      if (!_shown.isDismissed) c.wantFocus();
      _fadeLine(v, o, v < 1 ? (1 - o) / (1 - v) : 0);
      _reduced ? _shown.value = 1 : _shown.animateTo(1, curve: _curve);
    } else {
      final slope = o >= 1 ? 1 / math.max(math.min(v, _fadeFrom), 1e-6) : (v > 0 ? o / v : 1.0);
      _fadeLine(0, 0, slope);
      // The soft keyboard goes down under the panel, which stays until it has gone.
      c.releaseFocus();
      _reduced ? _shown.value = 0 : _shown.animateBack(0, curve: _curve);
    }
  }

  void _quickChanged() {
    final hidden = _quickHidden;
    if (hidden == _hidden) return;
    _hidden = hidden;
    if (_reduced) {
      _quick.value = hidden ? 0 : 1;
    } else if (hidden) {
      // Back, so it ends dismissed.
      _quick.animateBack(0, curve: _curve);
    } else {
      _quick.animateTo(1, curve: _curve);
    }
  }

  void _fadeLine(double v, double o, double slope) {
    _fadeV = v;
    _fadeO = o;
    _fadeSlope = slope;
  }

  double _opacity(double v) => (_fadeO + (v - _fadeV) * _fadeSlope).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    _reduced = MediaQuery.disableAnimationsOf(context);
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final defaultAt = ios ? defaultComposerAt : desktopComposerAt(controlHeightOf(context));
    return LayoutBuilder(
      builder: (context, c) => ListenableBuilder(
        listenable: Listenable.merge([_shown, _quick, widget.listenable, panelPlaceOf(widget.session)]),
        builder: (context, _) {
          final st = widget.state;
          final s = widget.session;
          final k = widget.keyboard;
          final textMounted = _open || !_shown.isDismissed;
          final quickMounted = !_hidden || !_quick.isDismissed;
          // A terminal's 复制 copies its stage's selection here; an app's sends ⌘C.
          final copy = widget.port is TermSessionPort ? () => s.termCopy?.call() : null;
          final buttons = stackButtonCount(s, voice: widget.voice);
          final upright = stackUprightOf(
              stage: c.biggest,
              block: panelPlaceOf(s).value,
              keyboard: k,
              columnHeight: stackColumnHeight(open: _open, buttons: buttons, voice: widget.voice));
          final stackHeight =
              _open ? openStackHeight(upright, widget.voice) : closedStackHeight(buttons: buttons, upright: upright);
          final bottom = stackBottomOf(stage: c.biggest, block: panelPlaceOf(s).value, keyboard: k, stackHeight: stackHeight);
          final block = !s.composerAllowed
              ? const SizedBox.shrink()
              // The stage's origin for where the block is (the stack stands above it).
              : StageMark(
                  child: FloatingComposer(
                    // Per session: a switch mid-drag drops that drag instead of saving it into the new app.
                    key: ValueKey(s.sid),
                    session: s,
                    at: st.composerAtOf(s),
                    defaultAt: defaultAt,
                    scale: st.composerScale,
                    keyboard: k,
                    place: panelPlaceOf(s),
                    onPlace: (p) => st.placeComposer(s, p),
                    onPullClose: ios && _open ? s.composer.collapse : null,
                    grip: textMounted || quickMounted,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (textMounted)
                          Flexible(
                            key: const Key('dock-text'),
                            child: IgnorePointer(
                              ignoring: !_open,
                              child: Opacity(
                                key: const Key('dock-panel-fade'),
                                opacity: _opacity(_shown.value),
                                child: ClipRect(
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    heightFactor: _shown.value,
                                    child: widget.text(context, c.maxHeight / 2),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (textMounted && quickMounted)
                          SizedBox(key: const Key('dock-gap'), height: 8 * math.min(_shown.value, _quick.value)),
                        if (quickMounted)
                          MetaData(
                            key: const Key('dock-quick'),
                            // A drag on a key is the key's (a swipe up for its other key), never a move.
                            metaData: composerNoDrag,
                            behavior: HitTestBehavior.translucent,
                            child: IgnorePointer(
                              ignoring: _hidden,
                              child: Opacity(
                                opacity: _quick.value,
                                child: ClipRect(
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    heightFactor: _quick.value,
                                    child: KeyBar(
                                      key: ValueKey(('quick', s.sid)),
                                      state: st,
                                      session: s,
                                      port: widget.port,
                                      onCopy: copy,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
          final stack = widget.stack(context, bottom, c.biggest, upright);
          return ClipRect(
            child: Stack(
              // iOS: the stack over the block (it stands above it); the desktop's corner row under the block.
              children: ios
                  ? [Positioned.fill(child: block), Positioned.fill(child: stack)]
                  : [Positioned.fill(child: stack), Positioned.fill(child: block)],
            ),
          );
        },
      ),
    );
  }
}
