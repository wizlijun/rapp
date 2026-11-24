// The input dock's block (floating-composer spec §4, input-dock spec): it floats over a still picture where the
// session's `composerAt` says, and a drag on it moves it.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderMetaData;

import '../ui/tokens.dart';
import 'app_profile.dart';
import 'composer_panel.dart' show panelWidth;
import 'panel_place.dart';
import 'remote_session.dart';

/// The panel keeps this far from every stage edge.
const composerMargin = 8.0;

/// The grip's hit area (spec: at least 48×20).
const gripSize = Size(48, 20);

/// The side handle's square (the quick area's handle, Task 5): it sits [_handleGap] beside the block.
const quickHandleSize = 28.0;
const _handleGap = 8.0;

/// Wrap a subtree in `MetaData(metaData: composerNoDrag)`: neither a drag nor a held touch starts a move there.
final composerNoDrag = Object();

/// Marks the panel's text area (a [MetaData] around the editor): there a mouse selects text and a
/// touch scrolls or selects as usual, and only a touch held still ([_holdToMove]) moves the panel.
/// Anywhere else on the panel a drag moves it at once.
final composerTextArea = Object();

/// How long a touch rests on the text before it moves the panel: under the text's own long press
/// (500ms), so the move wins.
const _holdToMove = Duration(milliseconds: 350);

/// No trackpad: a two-finger scroll over the panel scrolls the picture, it does not move the panel.
const _dragDevices = {
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

bool _onMeta(PointerEvent e, Object marker) {
  final r = HitTestResult();
  WidgetsBinding.instance.hitTestInView(r, e.position, e.viewId);
  return r.path.any((h) {
    final target = h.target;
    return target is RenderMetaData && identical(target.metaData, marker);
  });
}

/// How far past the lowest place a pull must go to collapse the panel, and how fast a fling down (px/s) does it.
const pullCloseDistance = 70.0;
const pullCloseSpeed = 700.0;

/// A drag that starts on the panel outside its text.
class PanelPan extends PanGestureRecognizer {
  PanelPan({super.debugOwner}) : super(supportedDevices: _dragDevices);

  @override
  bool isPointerAllowed(PointerEvent event) => super.isPointerAllowed(event) && !_onMeta(event, composerTextArea) && !_onMeta(event, composerNoDrag);
}

/// A touch held still on the text, then moved.
class _TextHold extends LongPressGestureRecognizer {
  _TextHold({super.debugOwner})
      : super(
          duration: _holdToMove,
          supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus},
        );

  @override
  bool isPointerAllowed(PointerDownEvent event) => super.isPointerAllowed(event) && _onMeta(event, composerTextArea) && !_onMeta(event, composerNoDrag);
}

/// Top-left of a [panel]-sized box whose bottom centre is [bc], kept [composerMargin] inside
/// [stage] and above the soft keyboard ([keyboard] up off the stage's bottom). Where a range is empty (a panel
/// larger than the stage), the left or top margin wins.
Offset _topLeftOf(Offset bc, Size stage, Size panel, [double keyboard = 0]) {
  const m = composerMargin;
  final left = math.max(m, math.min(bc.dx - panel.width / 2, stage.width - m - panel.width));
  final bottom = math.max(m + panel.height, math.min(bc.dy, stage.height - m - keyboard));
  return Offset(left, bottom - panel.height);
}

/// Where a [panel]-sized writing panel placed at [at] (its bottom centre) sits on [stage]:
/// its top-left, clamped inside the stage and above a [keyboard] that tall. The point itself is never changed by
/// the clamp: the panel goes back down when the keyboard does.
Offset composerTopLeft(InputPoint at, Size stage, Size panel, {double keyboard = 0}) =>
    _topLeftOf(at.inContent(stage), stage, panel, keyboard);

/// The writing panel ([child]) floating at the session's app's place, with the grip above it.
/// A drag on it (on its text, only after a touch held still) moves it and, on release, [onPlace]
/// gets the new place; a double-tap on the grip gives [onPlace] null (back to [defaultComposerAt]).
/// Either way the caret goes back to the editor.
class FloatingComposer extends StatefulWidget {
  const FloatingComposer(
      {super.key,
      required this.session,
      required this.at,
      this.defaultAt = defaultComposerAt,
      this.grip = true,
      this.handle,
      required this.onPlace,
      required this.child,
      this.scale = 1,
      this.keyboard = 0,
      this.place,
      this.onPullClose});

  /// iOS: pulled down past its lowest place (or flung down there), the panel asks to collapse. Null: no pull.
  final VoidCallback? onPullClose;

  /// Told where the panel (with its grip) is, when given: iOS's voice button stands above it.
  final ValueNotifier<Rect?>? place;

  /// The panel's zoom: its width is 720 × this.
  final double scale;

  /// How far the soft keyboard reaches up over the stage's bottom: the panel stays [composerMargin] above it.
  final double keyboard;

  final RemoteSession session;

  /// Where the block's bottom centre is saved; null: [defaultAt].
  final InputPoint? at;
  final InputPoint defaultAt;

  /// The grip row above the block (drag handle, double-tap reset). False: the block is only [child].
  final bool grip;

  /// A widget beside the block, bottoms level, 8 off its right edge (its left edge when that would leave the
  /// stage; 8 above the block, right edges level, when neither side has room). Not part of [place]'s rect, and
  /// outside the drag.
  final Widget? handle;

  final ValueChanged<InputPoint?> onPlace;
  final Widget child;

  @override
  State<FloatingComposer> createState() => _FloatingComposerState();
}

class _FloatingComposerState extends State<FloatingComposer> with SingleTickerProviderStateMixin {
  final _box = GlobalKey();

  /// How far the finger has pulled down past the lowest place: the panel is drawn this far lower (and the stack
  /// with it, which reads the panel's place). Never part of the saved place.
  double _over = 0;
  double _overFrom = 0;
  late final AnimationController _spring = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
    ..addListener(() => setState(() => _over = _overFrom * (1 - Curves.easeOut.transform(_spring.value))));

  @override
  void initState() {
    super.initState();
    _spring; // made now: a lazy one made in dispose() would look up a deactivated element
    widget.session.composer.addListener(_reopen);
  }

  // Opened again while the pull-close was going: the panel comes back from where the finger left it.
  void _reopen() {
    if (widget.session.composer.open && _drag == null) _springBack();
  }

  @override
  void dispose() {
    widget.session.composer.removeListener(_reopen);
    _spring.dispose();
    super.dispose();
  }

  /// The bottom centre while a drag is on, in stage coordinates; always where the panel is seen.
  Offset? _drag;
  Size _stage = Size.zero;

  /// The pointer is over the panel or its grip: only then (or while dragging) is the bar drawn.
  bool _hover = false;

  /// A touch landed on the panel and no tap elsewhere since: a touch screen has no hover, so this
  /// shows the bar instead.
  bool _touched = false;

  /// Where the held touch was last, for its moves.
  Offset? _held;

  InputPoint get _at => widget.at ?? widget.defaultAt;

  Size get _panel => _box.currentContext?.size ?? Size.zero;

  /// Where the bottom centre is seen for a wanted one ([bc]): after the clamp.
  Offset _seen(Offset bc) {
    final p = _panel;
    return _topLeftOf(bc, _stage, p, widget.keyboard) + Offset(p.width / 2, p.height);
  }

  /// Where the panel was seen when the drag began: a drop there writes no place (a default stays unwritten).
  Offset? _from;

  void _start() {
    _spring.stop();
    // A stale pull must never make this drag collapse by itself.
    _over = 0;
    setState(() => _from = _drag = _seen(_at.inContent(_stage)));
  }

  // Moved from where it is seen, so going past an edge and back has no dead zone. What the bottom clamp
  // swallows of a downward move is the pull ([_over]).
  void _move(Offset delta) {
    final p = _panel;
    final lowest = math.max(composerMargin + p.height, _stage.height - composerMargin - widget.keyboard);
    final wanted = (_drag ?? _at.inContent(_stage)) + Offset(0, _over) + delta;
    setState(() {
      _drag = _seen(wanted);
      if (widget.onPullClose != null) _over = math.max(0, wanted.dy - lowest);
    });
  }

  void _end([Velocity? v]) {
    _held = null;
    final bc = _drag;
    if (bc == null) return;
    // Pulled past the bottom: the place is the lowest there is, not the keyboard-relative clamp.
    final p = _over > 0 ? InputPoint(InputPoint.at(bc, _stage).x, composerMargin, fromBottom: true) : InputPoint.at(bc, _stage);
    // Dropped where it was: nothing to write (a default stays unwritten).
    if (bc != _from && p != _at) widget.onPlace(p);
    setState(() => _drag = null);
    final pull = widget.onPullClose;
    if (pull != null && _over > 0 && (_over > pullCloseDistance || (v?.pixelsPerSecond.dy ?? 0) > pullCloseSpeed)) {
      // The text area folds; the block (the 快捷区 stays in it) goes back up from where the finger left it.
      pull();
      _springBack();
      return;
    }
    _springBack();
    widget.session.composer.wantFocus();
  }

  void _cancel() {
    _held = null;
    setState(() => _drag = null);
    _springBack();
  }

  void _springBack() {
    if (_over <= 0) return;
    _overFrom = _over;
    _spring.forward(from: 0);
  }

  void _reset() {
    widget.onPlace(null);
    widget.session.composer.wantFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    // The drag itself is the panel's (below); the grip shows where to take it, and resets on a double-tap.
    final gripRow = !widget.grip ? null : GestureDetector(
      key: const Key('composer-grip'),
      behavior: HitTestBehavior.opaque,
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
              // Hidden but still there to grab: the bar only shows with the pointer over the panel.
              child: Center(
                child: AnimatedOpacity(
                  key: const Key('composer-grip-bar'),
                  opacity: _hover || _touched || _drag != null ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
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
      ),
    );
    return LayoutBuilder(builder: (context, c) {
      _stage = c.biggest;
      final handle = widget.handle;
      return CustomMultiChildLayout(
        delegate: _Place(_drag ?? _at.inContent(_stage), panelWidth(_stage.width, widget.scale), widget.keyboard,
            handle != null),
        children: [
          LayoutId(
            id: _block,
            child: Transform.translate(
              offset: Offset(0, _over),
              child: _placed(TapRegion(
                onTapOutside: (_) {
                  if (_touched) setState(() => _touched = false);
                },
                child: Listener(
                  onPointerDown: (e) {
                    if (!_touched && e.kind != PointerDeviceKind.mouse && e.kind != PointerDeviceKind.trackpad) {
                      setState(() => _touched = true);
                    }
                  },
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _hover = true),
                    onExit: (_) => setState(() => _hover = false),
                    child: RawGestureDetector(
                      gestures: {
                        PanelPan: GestureRecognizerFactoryWithHandlers<PanelPan>(
                          () => PanelPan(debugOwner: this),
                          (r) => r
                            ..dragStartBehavior = DragStartBehavior.down
                            ..onStart = ((_) => _start())
                            ..onUpdate = ((d) => _move(d.delta))
                            ..onEnd = ((d) => _end(d.velocity))
                            ..onCancel = _cancel,
                        ),
                        _TextHold: GestureRecognizerFactoryWithHandlers<_TextHold>(
                          () => _TextHold(debugOwner: this),
                          (r) => r
                            ..onLongPressStart = (d) {
                              _held = d.globalPosition;
                              _start();
                            }
                            ..onLongPressMoveUpdate = (d) {
                              final from = _held ?? d.globalPosition;
                              _held = d.globalPosition;
                              _move(d.globalPosition - from);
                            }
                            ..onLongPressEnd = ((d) => _end(d.velocity))
                            ..onLongPressCancel = _cancel,
                        ),
                      },
                      child: Column(
                        key: _box,
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (gripRow != null) Center(child: gripRow),
                          Flexible(child: widget.child),
                        ],
                      ),
                    ),
                  ),
                ),
              )),
            ),
          ),
          if (handle != null)
            LayoutId(id: _handle, child: Transform.translate(offset: Offset(0, _over), child: handle)),
        ],
      );
    });
  }

  Widget _placed(Widget w) => widget.place == null ? w : PanelPlace(place: widget.place!, child: w);
}

const _block = #block;
const _handle = #handle;

class _Place extends MultiChildLayoutDelegate {
  _Place(this.bc, this.width, this.keyboard, this.hasHandle);

  final Offset bc;
  final double width;
  final double keyboard;
  final bool hasHandle;

  @override
  void performLayout(Size size) {
    // Only the room above the keyboard: a taller panel would reach under it.
    final block = layoutChild(
        _block,
        BoxConstraints(
            minWidth: width, maxWidth: width, maxHeight: math.max(0, size.height - 2 * composerMargin - keyboard)));
    final at = _topLeftOf(bc, size, block, keyboard);
    positionChild(_block, at);
    if (!hasHandle) return;
    final h = layoutChild(_handle, const BoxConstraints());
    var left = at.dx + block.width + _handleGap;
    var top = at.dy + block.height - h.height;
    if (left + h.width > size.width - composerMargin) left = at.dx - _handleGap - h.width;
    if (left < composerMargin) {
      // No room on either side (a block near the stage's width): above it, right edges level.
      left = at.dx + block.width - h.width;
      top = at.dy - _handleGap - h.height;
    }
    left = math.max(0, math.min(left, size.width - h.width));
    top = math.max(0, math.min(top, size.height - h.height));
    positionChild(_handle, Offset(left, top));
  }

  @override
  bool shouldRelayout(_Place old) =>
      old.bc != bc || old.width != width || old.keyboard != keyboard || old.hasHandle != hasHandle;
}
