// iOS's dock (iOS input toggle): bottom to top, the soft keyboard, the key bar, the writing panel 8 above the bar and
// the stage's button stack, moving as one. One controller says how far the panel is shown; the keyboard is followed
// live, frame by frame, and with no soft keyboard the dock moves itself.
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../term/term_session_port.dart';
import '../ui/main_state.dart';
import '../ui/terms_entry.dart';
import 'composer_float.dart' show PanelPan, pullCloseDistance, pullCloseSpeed;
import 'composer_model.dart' show ComposerModel;
import 'key_bar.dart';
import 'panel_place.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'stage_buttons.dart';

/// A move the dock makes itself, with no soft keyboard to follow: the panel going down, the stack between its ends.
const dockMove = Duration(milliseconds: 340);
const _curve = Curves.easeOutCubic;

/// A closing panel fades out over its last this long; an opening one fades in as it comes up.
const _fadeOut = Duration(milliseconds: 100);

// The eased "shown" at which a close from fully open has [_fadeOut] left.
final _fadeFrom = 1 - _curve.transform(1 - _fadeOut.inMicroseconds / dockMove.inMicroseconds);

/// The key bar stays at the stage's bottom with the panel closed: a terminal session, or an app that is a terminal.
bool keyBarWhenClosed(RemoteSession s, SessionPort port) => port is TermSessionPort || terminalApps.contains(s.appId);

/// The open stack's height: 语音 and 收起 in one row, one above the other, or 收起 alone.
double openStackHeight(bool upright, bool voice) => upright || !voice ? stageButtonSize : 2 * stageButtonSize + 12;

/// The closed stack's bottom over a [bar] that tall (0: none): [stageButtonsUp], and clear of the bar; on a soft
/// keyboard [stageButtonsEdge] above the bar standing on it (never lower than without one).
double closedStackBottom(double keyboard, double bar) => math.max(
    math.max(stageButtonsUp, bar + 8), keyboard > 0 ? keyboard + bar + stageButtonsEdge : 0);

/// Lays out iOS's dock over the whole stage. While the panel is open: the [KeyBar] full width on the [keyboard]
/// (the stage's bottom without one), the [panel] 8 above it, the [stack] 8 above the panel. Closed: the stack at
/// [closedStackBottom], over a bar only where [keyBarWhenClosed].
///
/// A close keeps the panel until it has gone: it rides the falling keyboard, or with none goes down by its own
/// height in [dockMove]; either way it fades out over the last 100 ms. An open is the same move the other way: up by
/// its own height when no keyboard is up yet (one that then rises lifts it further), fading in all the way. Open
/// again before a close is over and the same panel comes back, from the place and the opacity it had. The stack's
/// place is one value eased between its closed and open ends by the same controller, each end following the keyboard.
class IosDock extends StatefulWidget {
  const IosDock(
      {super.key,
      required this.state,
      required this.session,
      required this.port,
      required this.keyboard,
      required this.listenable,
      required this.voice,
      required this.panel,
      required this.stack});

  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  /// How far the soft keyboard reaches up over the stage's bottom.
  final double keyboard;

  /// What [panel] and [stack] are built from, beyond the session's panel.
  final Listenable listenable;

  /// The stack has 语音 (it stands higher in a column).
  final bool voice;

  /// The writing panel standing 8 above [rest] up off the stage's bottom (the bar's top); the dock lowers it when
  /// it goes down by itself.
  final Widget Function(BuildContext context, double rest) panel;

  /// The button stack, its bottom [bottom] up off the stage's bottom.
  final Widget Function(BuildContext context, double bottom, Size stage) stack;

  @override
  State<IosDock> createState() => IosDockState();
}

class IosDockState extends State<IosDock> with SingleTickerProviderStateMixin {
  late bool _open = _wanted;
  late final AnimationController _shown = AnimationController(vsync: this, duration: dockMove, value: _open ? 1 : 0);

  // This move goes by itself (down, or up from below): no soft keyboard when it began from rest.
  bool _sink = false;

  // The panel's opacity is a line in "shown" through (_fadeV, _fadeO), clamped to 0..1. A close from open is opaque
  // down to [_fadeFrom], then goes to 0 with it; an open goes from where it is to 1 with "shown" at 1. A turn mid-move
  // starts the new line from the opacity it had, so it never snaps.
  double _fadeV = 0, _fadeO = 0, _fadeSlope = 1 / _fadeFrom;
  bool _reduced = false;
  double _bar = 0;
  double _stage = 0;

  bool get _wanted => widget.session.composer.open && widget.session.composerAllowed;

  /// The panel's bottom offset off the stage's bottom, less the 8 it stands above that: the bar's top on the
  /// keyboard, lowered by the panel's height (and the 8) times what is left of a move it makes by itself.
  double get panelBottom => widget.keyboard + _bar - _drop;

  double get _drop {
    if (!_sink) return 0;
    // Before its first layout the panel's height is not known yet: it waits below the stage, out of sight.
    final h = panelPlaceOf(widget.session).value?.height ?? _stage;
    return (1 - _shown.value) * (h + 8);
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    widget.session.composer.addListener(_changed);
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    widget.session.composer.removeListener(_changed);
    _shown.dispose();
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
      if (_shown.isDismissed) {
        _sink = widget.keyboard == 0;
      } else {
        // Back before the close was over: the panel is the one still there, so it takes the caret itself.
        c.wantFocus();
      }
      _fadeLine(v, o, v < 1 ? (1 - o) / (1 - v) : 0);
      _reduced ? _shown.value = 1 : _shown.animateTo(1, curve: _curve);
    } else {
      if (_shown.isCompleted) _sink = widget.keyboard == 0;
      final slope = o >= 1 ? 1 / math.max(math.min(v, _fadeFrom), 1e-6) : (v > 0 ? o / v : 1.0);
      _fadeLine(0, 0, slope);
      // The keyboard goes down under the panel, which stays until it has gone.
      c.releaseFocus();
      _reduced ? _shown.value = 0 : _shown.animateBack(0, curve: _curve);
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
    final s = widget.session;
    return LayoutBuilder(
      builder: (context, c) => ListenableBuilder(
        listenable: Listenable.merge([_shown, widget.listenable, panelPlaceOf(s)]),
        builder: (context, _) {
          final k = widget.keyboard;
          final v = _shown.value;
          final shown = _open || !_shown.isDismissed;
          final stays = keyBarWhenClosed(s, widget.port);
          // A terminal's 复制 copies its stage's selection here; an app's sends ⌘C.
          final copy = widget.port is TermSessionPort ? () => s.termCopy?.call() : null;
          final barH = keyBarHeightOf(widget.state, s, c.maxWidth);
          _bar = shown || stays ? barH : 0;
          _stage = c.maxHeight;
          final fade = _opacity(v);
          final drop = _drop;
          // The stack: closed over the bar it keeps, open 8 above the panel's top (a frame behind it), and never
          // off the stage's top; eased between the two.
          final closed = closedStackBottom(k, stays ? barH : 0);
          final panel = panelPlaceOf(s).value;
          final h = openStackHeight(c.maxHeight > c.maxWidth, widget.voice);
          final above = panel == null ? closed : math.min(c.maxHeight - panel.top + 8, c.maxHeight - 8 - h);
          final bottom = math.max(closed, lerpDouble(closed, above, v)!);
          return ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                  // The stage's origin for where the panel is (the stack stands above it).
                  child: StageMark(
                    child: shown
                        ? IgnorePointer(
                            ignoring: !_open,
                            child: Opacity(
                              key: const Key('dock-panel-fade'),
                              opacity: fade,
                              child: Transform.translate(
                                offset: Offset(0, drop),
                                child: widget.panel(context, k + barH),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                // Always in the list: the stack after it stays the same element.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: k,
                  child: stays
                      ? KeyBar(state: widget.state, session: s, port: widget.port, onCopy: copy)
                      : !shown
                          ? const SizedBox.shrink()
                          // A bar that goes with the panel goes the way it does.
                          : IgnorePointer(
                              ignoring: !_open,
                              child: Opacity(
                                opacity: fade,
                                child: Transform.translate(
                                  offset: Offset(0, _sink ? (1 - v) * barH : 0),
                                  child: KeyBar(state: widget.state, session: s, port: widget.port, onCopy: copy),
                                ),
                              ),
                            ),
                ),
                Positioned.fill(child: widget.stack(context, bottom, c.biggest)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A pull down on the terminal panel (anywhere but its text, as [PanelPan] says): the panel follows the finger, and on
/// release past [pullCloseDistance] or a fling down the composer is collapsed, from where the panel is. Otherwise it springs
/// back in 200 ms. Put it outside the panel's [PanelPlace], so the place (and the stack above it) follows.
class PullDown extends StatefulWidget {
  const PullDown({super.key, required this.composer, required this.child});

  /// Collapsed by a pull; opening again brings the panel back.
  final ComposerModel composer;
  final Widget child;

  @override
  State<PullDown> createState() => _PullDownState();
}

class _PullDownState extends State<PullDown> with SingleTickerProviderStateMixin {
  double _over = 0, _from = 0;
  late final AnimationController _spring = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
    ..addListener(() => setState(() => _over = _from * (1 - Curves.easeOut.transform(_spring.value))));

  @override
  void initState() {
    super.initState();
    _spring; // made now: a lazy one made in dispose() would look up a deactivated element
    widget.composer.addListener(_reopen);
  }

  void _reopen() {
    if (widget.composer.open) _back();
  }

  @override
  void dispose() {
    widget.composer.removeListener(_reopen);
    _spring.dispose();
    super.dispose();
  }

  void _end(Velocity v) {
    if (_over > pullCloseDistance || (_over > 0 && v.pixelsPerSecond.dy > pullCloseSpeed)) return widget.composer.collapse();
    _back();
  }

  void _back() {
    if (_over <= 0) return;
    _from = _over;
    _spring.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => Transform.translate(
        offset: Offset(0, _over),
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            PanelPan: GestureRecognizerFactoryWithHandlers<PanelPan>(
              () => PanelPan(debugOwner: this),
              (r) => r
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = ((_) {
                  _spring.stop();
                  _over = 0; // a stale pull must never close by itself
                })
                ..onUpdate = ((d) => setState(() => _over = math.max(0, _over + d.delta.dy)))
                ..onEnd = ((d) => _end(d.velocity))
                ..onCancel = _back,
            ),
          },
          child: widget.child,
        ),
      );
}
