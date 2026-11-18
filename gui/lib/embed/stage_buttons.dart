import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../ui/prefs.dart';

/// Where the stage's button stack rests: its outer edge [stageButtonsIn] in from the screen edge and its bottom
/// [stageButtonsUp] up, so the voice button (the lowest) is where a thumb holding the phone reaches without
/// stretching to the corner (user 2026-11-18: 「放在大拇指最容易单手按到的位置」).
const stageButtonsIn = 80.0;
const stageButtonsUp = 88.0;

/// The gap above whatever the stack stands on in place of the stage's bottom: the soft keyboard.
const stageButtonsEdge = 12.0;

const _gap = 12.0;
const _fade = Duration(milliseconds: 120);
const _glide = Duration(milliseconds: 200);

/// The stage's round buttons (iOS) as one vertical stack on a screen edge, bottom to top: [voice], [input],
/// [restore]. [beside] widgets stack upward on the inner side, bottom-aligned with the stack's lowest button.
/// A horizontal drag on [input] or [restore] moves the stack to the other side once it passes the middle.
///
/// [hidden] (recording) fades [input], [restore] and [beside] out, ignores their input and turns dragging
/// off; [voice] keeps its place and draws itself.
class StageButtons extends StatefulWidget {
  const StageButtons({
    super.key,
    required this.side,
    required this.onSide,
    this.voice,
    this.input,
    this.restore,
    this.beside = const [],
    this.hidden = false,
  });

  final StageSide side;
  final ValueChanged<StageSide> onSide;
  final Widget? voice;
  final Widget? input;
  final Widget? restore;
  final List<Widget> beside;
  final bool hidden;

  @override
  State<StageButtons> createState() => _StageButtonsState();
}

class _StageButtonsState extends State<StageButtons>
    with SingleTickerProviderStateMixin {
  final _column = GlobalKey();
  // Idle at 1: the stack is at its edge. A snap sets [_from] and runs it 0 to 1.
  late final AnimationController _snap = AnimationController(
    vsync: this,
    value: 1,
  );
  bool _dragging = false;
  // The stack's horizontal offset from its edge while dragging, and where a snap starts from.
  double _dx = 0;
  double _from = 0;
  double _stageWidth = 0;

  @override
  void didUpdateWidget(StageButtons old) {
    super.didUpdateWidget(old);
    // Hiding drops the drag recognizer without an end: snap back to this side instead of freezing mid-way.
    if (widget.hidden && !old.hidden && _dragging) {
      _dragging = false;
      _from = _dx;
      _snap.duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : _glide;
      _snap.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  double get _offset =>
      _dragging ? _dx : _from * (1 - Curves.easeOut.transform(_snap.value));

  double _columnWidth() =>
      (_column.currentContext?.findRenderObject() as RenderBox?)?.size.width ??
      0;

  // The stack's centre when it rests on [s].
  double _rest(StageSide s, double w) => s == StageSide.left
      ? stageButtonsIn + w / 2
      : _stageWidth - stageButtonsIn - w / 2;

  void _start(DragStartDetails _) {
    _dx = _offset;
    _snap.value = 1;
    setState(() => _dragging = true);
  }

  void _update(DragUpdateDetails d) => setState(() => _dx += d.delta.dx);

  void _end([Object? _]) {
    if (!_dragging) return;
    final w = _columnWidth();
    final centre = _rest(widget.side, w) + _dx;
    final to = centre < _stageWidth / 2 ? StageSide.left : StageSide.right;
    setState(() {
      _dragging = false;
      _from = centre - _rest(to, w);
    });
    _snap.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _glide;
    _snap.forward(from: 0);
    if (to != widget.side) widget.onSide(to);
  }

  Widget _faded(Widget child, bool reduced) => AnimatedOpacity(
    opacity: widget.hidden ? 0 : 1,
    duration: reduced ? Duration.zero : _fade,
    child: IgnorePointer(ignoring: widget.hidden, child: child),
  );

  Widget _draggable(Widget child) => RawGestureDetector(
    gestures: widget.hidden
        ? const {}
        : {
            HorizontalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  HorizontalDragGestureRecognizer
                >(
                  () => HorizontalDragGestureRecognizer(),
                  (r) => r
                    ..gestureSettings = const DeviceGestureSettings(
                      touchSlop: 10,
                    )
                    ..onStart = _start
                    ..onUpdate = _update
                    ..onEnd = _end
                    ..onCancel = _end,
                ),
          },
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final left = widget.side == StageSide.left;
    final stack = <Widget>[
      if (widget.voice != null) widget.voice!,
      if (widget.input != null) _faded(_draggable(widget.input!), reduced),
      if (widget.restore != null) _faded(_draggable(widget.restore!), reduced),
    ];
    final column = Column(
      key: _column,
      mainAxisSize: MainAxisSize.min,
      verticalDirection: VerticalDirection.up,
      children: [
        for (var i = 0; i < stack.length; i++) ...[
          if (i > 0) const SizedBox(height: _gap),
          stack[i],
        ],
      ],
    );
    final beside = widget.beside.isEmpty
        ? null
        : _faded(
            Column(
              mainAxisSize: MainAxisSize.min,
              verticalDirection: VerticalDirection.up,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < widget.beside.length; i++) ...[
                  if (i > 0) const SizedBox(height: _gap),
                  widget.beside[i],
                ],
              ],
            ),
            reduced,
          );
    return LayoutBuilder(
      builder: (context, c) {
        _stageWidth = c.maxWidth;
        return AnimatedBuilder(
          animation: _snap,
          builder: (context, _) => Align(
            alignment: left ? Alignment.bottomLeft : Alignment.bottomRight,
            child: Padding(
              // The bottom is the caller's: it knows what the stack stands on.
              padding: const EdgeInsets.symmetric(horizontal: stageButtonsIn),
              child: Transform.translate(
                offset: Offset(_offset, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (left && stack.isNotEmpty) column,
                    if (beside != null) ...[
                      if (!left) beside,
                      if (stack.isNotEmpty) const SizedBox(width: _gap),
                      if (left) beside,
                    ],
                    if (!left && stack.isNotEmpty) column,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
