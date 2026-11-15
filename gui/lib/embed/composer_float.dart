// The writing panel over an app window (floating-composer spec §4): it floats over a still
// picture where the app's `composerAt` says, and a grip on its top edge moves it. Terminals keep
// the bottom-centre panel and the lift (composer_panel.dart).
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior, PointerDeviceKind;
import 'package:flutter/material.dart';

import '../ui/tokens.dart';
import 'app_profile.dart';
import 'composer_panel.dart' show panelWidth;
import 'remote_session.dart';

/// The panel keeps this far from every stage edge.
const composerMargin = 8.0;

/// The grip's hit area (spec: at least 48×20).
const gripSize = Size(48, 20);

/// Top-left of a [panel]-sized box whose bottom centre is [bc], kept [composerMargin] inside
/// [stage]. Where a range is empty (a panel larger than the stage), the left or top margin wins.
Offset _topLeftOf(Offset bc, Size stage, Size panel) {
  const m = composerMargin;
  final left = math.max(m, math.min(bc.dx - panel.width / 2, stage.width - m - panel.width));
  final bottom = math.max(m + panel.height, math.min(bc.dy, stage.height - m));
  return Offset(left, bottom - panel.height);
}

/// Where a [panel]-sized writing panel placed at [at] (its bottom centre) sits on [stage]:
/// its top-left, clamped inside the stage. The point itself is never changed by the clamp.
Offset composerTopLeft(InputPoint at, Size stage, Size panel) => _topLeftOf(at.inContent(stage), stage, panel);

/// The writing panel ([child]) floating at the session's app's place, with the grip above it.
/// A drag moves it and, on release, [onPlace] gets the new place; a double-tap on the grip gives
/// [onPlace] null (back to [defaultComposerAt]). Either way the caret goes back to the editor.
class FloatingComposer extends StatefulWidget {
  const FloatingComposer({super.key, required this.session, required this.onPlace, required this.child});

  final RemoteSession session;
  final ValueChanged<InputPoint?> onPlace;
  final Widget child;

  @override
  State<FloatingComposer> createState() => _FloatingComposerState();
}

class _FloatingComposerState extends State<FloatingComposer> {
  final _box = GlobalKey();

  /// The bottom centre while a drag is on, in stage coordinates; always where the panel is seen.
  Offset? _drag;
  Size _stage = Size.zero;

  InputPoint get _at => widget.session.profile.composerAt ?? defaultComposerAt;

  Size get _panel => _box.currentContext?.size ?? Size.zero;

  /// Where the bottom centre is seen for a wanted one ([bc]): after the clamp.
  Offset _seen(Offset bc) {
    final p = _panel;
    return _topLeftOf(bc, _stage, p) + Offset(p.width / 2, p.height);
  }

  void _start(DragStartDetails _) => setState(() => _drag = _seen(_at.inContent(_stage)));

  // Moved from where it is seen, so going past an edge and back has no dead zone.
  void _update(DragUpdateDetails d) => setState(() => _drag = _seen((_drag ?? _at.inContent(_stage)) + d.delta));

  void _end(DragEndDetails _) {
    final bc = _drag;
    if (bc == null) return;
    widget.onPlace(InputPoint.at(bc, _stage));
    setState(() => _drag = null);
    widget.session.composer.wantFocus();
  }

  void _cancel() => setState(() => _drag = null);

  void _reset() {
    widget.onPlace(null);
    widget.session.composer.wantFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final grip = GestureDetector(
      key: const Key('composer-grip'),
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      // No trackpad: a two-finger scroll over the grip scrolls the picture, it does not move the panel.
      supportedDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.unknown,
      },
      onPanStart: _start,
      onPanUpdate: _update,
      onPanEnd: _end,
      onPanCancel: _cancel,
      onDoubleTap: _reset,
      child: MouseRegion(
        cursor: _drag == null ? SystemMouseCursors.grab : SystemMouseCursors.grabbing,
        child: Tooltip(
          message: '拖动；双击回到底部居中',
          // Hover only: a long-press tooltip would take a touch held still before it moves.
          triggerMode: TooltipTriggerMode.manual,
          child: Semantics(
            label: '移动写作面板',
            child: SizedBox.fromSize(
              size: gripSize,
              child: Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(color: t.line, borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return LayoutBuilder(builder: (context, c) {
      _stage = c.biggest;
      return CustomSingleChildLayout(
        delegate: _Place(_drag ?? _at.inContent(_stage), panelWidth(_stage.width)),
        child: Column(
          key: _box,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: grip),
            Flexible(child: widget.child),
          ],
        ),
      );
    });
  }
}

class _Place extends SingleChildLayoutDelegate {
  _Place(this.bc, this.width);

  final Offset bc;
  final double width;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => BoxConstraints(
      minWidth: width, maxWidth: width, maxHeight: math.max(0, c.maxHeight - 2 * composerMargin));

  @override
  Offset getPositionForChild(Size size, Size child) => _topLeftOf(bc, size, child);

  @override
  bool shouldRelayout(_Place old) => old.bc != bc || old.width != width;
}
