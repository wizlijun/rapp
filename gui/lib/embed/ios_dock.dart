// iOS's dock (iOS input toggle): bottom to top, the soft keyboard, the key bar, the writing panel 8 above the bar and
// the stage's button stack, moving as one. One controller says how far the panel is shown; the keyboard is followed
// live, frame by frame, and with no soft keyboard the dock moves itself.
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../term/term_session_port.dart';
import '../ui/main_state.dart';
import '../ui/terms_entry.dart';
import 'key_bar.dart';
import 'panel_place.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'stage_buttons.dart';

/// A move the dock makes itself, with no soft keyboard to follow: the panel going down, the stack between its ends.
const dockMove = Duration(milliseconds: 340);
const _curve = Curves.easeOutCubic;

/// A closing panel fades out over its last this long.
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
/// height in [dockMove]; either way it fades out over the last 100 ms. Open again before that and the same panel comes
/// back. The stack's place is one value eased between its closed and open ends by the same controller, each end
/// following the keyboard.
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

  // This close goes down by itself: no soft keyboard when it began.
  bool _sink = false;
  bool _reduced = false;
  double _bar = 0;

  bool get _wanted => widget.session.composer.open && widget.session.composerAllowed;

  /// The panel's bottom offset off the stage's bottom, less the 8 it stands above that: the bar's top on the
  /// keyboard, lowered by the panel's height (and the 8) times what is left of a close that goes down by itself.
  double get panelBottom => widget.keyboard + _bar - _drop;

  double get _drop {
    if (!_sink) return 0;
    final h = panelPlaceOf(widget.session).value?.height ?? 0;
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
    if (open) {
      // Back before the close was over: the panel is the one still there, so it takes the caret itself.
      if (!_shown.isDismissed) {
        c.wantFocus();
      } else {
        _sink = false;
      }
      _reduced ? _shown.value = 1 : _shown.animateTo(1, curve: _curve);
    } else {
      _sink = widget.keyboard == 0;
      // The keyboard goes down under the panel, which stays until it has gone.
      c.releaseFocus();
      _reduced ? _shown.value = 0 : _shown.animateBack(0, curve: _curve);
    }
  }

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
          final barH = keyBarHeightOf(widget.state, s, c.maxWidth);
          _bar = shown || stays ? barH : 0;
          final fade = _open ? 1.0 : math.min(1.0, v / _fadeFrom);
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
                      ? KeyBar(state: widget.state, session: s, port: widget.port)
                      : !shown
                          ? const SizedBox.shrink()
                          // A bar that goes with the panel goes the way it does.
                          : IgnorePointer(
                              ignoring: !_open,
                              child: Opacity(
                                opacity: fade,
                                child: Transform.translate(
                                  offset: Offset(0, _sink ? (1 - v) * barH : 0),
                                  child: KeyBar(state: widget.state, session: s, port: widget.port),
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
