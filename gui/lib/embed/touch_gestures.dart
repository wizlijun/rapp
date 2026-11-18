// Fingers on a picture or a terminal, turned into what they mean (pinch-zoom spec §6.2): the touch rules T1–T8
// (touch-scroll spec, iPad spec §8.1) plus the zoom's own — pan when zoomed, pinch, a trackpad's scale.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';

/// A finger held back this long, or moved this far from where it landed, is a press (T1).
const touchSlop = 8.0;
const touchHold = Duration(milliseconds: 150);

/// Zoomed in, a finger that moves pans the view; held this long without moving it presses.
const zoomedHold = Duration(milliseconds: 500);

/// Two fingers whose distance changes by more than this before their centre moved [touchSlop] pinch.
const pinchSlop = 12.0;

/// T8: two fingers that stay within [twoTapSlop] of where their centre started and all lift within [twoTapTime] of
/// the second one landing are a right tap.
const twoTapTime = Duration(milliseconds: 250);
const twoTapSlop = 8.0;

/// What fingers mean on a picture and on a terminal alike (pinch-zoom spec §6.2): one recognizer for both.
abstract interface class TouchSink {
  /// A finger press now; `e` is the finger's down event. True: the sink took a real press, and this finger is held
  /// (its moves are [drag]s, its lift a [release], other fingers are ignored meanwhile, T2). False: nothing was
  /// pressed (a 「标记输入区」 mark, no button bit), the finger is not held, and a second finger makes a two-finger
  /// gesture. A press outside the picture is never held, whatever this returns.
  bool press(PointerDownEvent e);

  /// The pressed finger moved.
  void drag(PointerMoveEvent e);

  /// The pressed finger lifted or was cancelled; a tap's `at` is where it landed.
  void release(Offset at, PointerEvent e);

  /// Two fingers' centre moved (one call per event batch, T3), logical px.
  void scroll(Offset centre, Offset delta);

  /// T8.
  void rightTap(Offset at);

  /// A second finger landed (T7: take focus).
  void twoDown(Offset centre);

  /// Move the view.
  void pan(Offset delta);

  /// The zoom is now z (unclamped), about focal.
  void zoom(double z, Offset focal);

  /// All fingers up after a pan or a zoom (and a trackpad zoom's end).
  void settled();
}

/// What a two-finger gesture turned out to be.
enum _Two { undecided, scroll, pinch }

class TouchGestures {
  TouchGestures({required this.sink, required this.zoom, required this.inside, this.zoomable = false});

  /// Where the intents go; the zoom now; whether a finger landing at a point (local) is on the picture or terminal;
  /// and whether fingers and a trackpad can zoom at all (`pinchZoom`: iOS only).
  final TouchSink sink;
  final double Function() zoom;
  final bool Function(Offset local) inside;
  final bool zoomable;

  /// Where each finger counted is now (a finger landing during a two-finger gesture is not, T5).
  final _touches = <int, Offset>{};

  /// A first finger not yet sent (T1, or zoomed: not yet a pan or a press), and whether it lands zoomed.
  PointerDownEvent? _pending;
  bool _pendingZoomed = false;
  Timer? _pendingTimer;

  /// The finger whose press went out and is still down (T2), and the finger panning the view.
  int? _pressed;
  int? _panning;

  /// The two-finger gesture, from the second finger down until all are up (T4): what it is, when and where it
  /// started, whether it can still be a right tap (T8), the centre's move held back while undecided, and for a
  /// pinch the zoom and the fingers' distance at the start and the centre last sent.
  _Two? _two;
  Duration _twoAt = Duration.zero;
  Offset _twoStart = Offset.zero;
  bool _twoMoved = false;
  Offset _twoBuffer = Offset.zero;
  double _pinchZoom = 1;
  double _pinchDistance = 0;
  Offset _pinchCentre = Offset.zero;

  /// The view moved during this gesture (a pan or a pinch): [TouchSink.settled] when all fingers are up.
  bool _viewMoved = false;

  /// T3: the fingers' moves of one event batch are taken together, once all of them are in: the scroll or pinch
  /// decision, one scroll, one pinch step. iOS hands the moved fingers over one by one, so a single finger's move is
  /// half a batch. [_batch] goes up at every [reset], so a batch queued before it is dropped.
  Offset _scrollAcc = Offset.zero;
  Offset _scrollAt = Offset.zero;
  bool _scrollPending = false;
  bool _pinchDirty = false;
  bool _batchQueued = false;

  /// Undecided fingers moved since the last decision. Only those moves are judged, with the fingers that made them: a
  /// lift decides before the centre jumps to the fingers left, so the batch's end must not judge the same moves again.
  bool _toDecide = false;
  int _batch = 0;

  /// A trackpad gesture: the zoom at its start, and whether it zoomed.
  double _padZoom = 1;
  bool _padZoomed = false;

  Offset get _centre => _touches.values.reduce((a, b) => a + b) / _touches.length.toDouble();

  void down(PointerDownEvent e) {
    if (_two != null) {
      _twoMoved = true; // T5: not counted, its moves and lift are ignored; and no longer a right tap
      return;
    }
    _touches[e.pointer] = e.localPosition;
    if (_pending != null || _panning != null || (_pressed == null && _touches.length > 1)) {
      // A second finger while the first is held back, pans, rests outside, or stayed after a press it was ignored
      // for: a two-finger gesture; a held-back press never happened.
      _dropPending();
      _panning = null;
      _two = _Two.undecided;
      _twoAt = e.timeStamp;
      _twoStart = _centre;
      _twoMoved = false;
      _twoBuffer = Offset.zero;
      _pinchDistance = _distance;
      sink.twoDown(_twoStart); // T7
      return;
    }
    if (_pressed != null) return; // T2
    final zoomed = zoom() > 1;
    if (!zoomed && !inside(e.localPosition)) {
      sink.press(e); // outside: blurs now, holds nothing
      return;
    }
    _pending = e;
    _pendingZoomed = zoomed;
    _pendingTimer = Timer(zoomed ? zoomedHold : touchHold, _flush);
  }

  /// Sends the held-back press (T1; zoomed: held still [zoomedHold]); the finger is held if the sink took it.
  void _flush() {
    final e = _pending;
    _dropPending();
    if (e != null && sink.press(e)) _pressed = e.pointer;
  }

  void _dropPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pending = null;
  }

  void move(PointerMoveEvent e) {
    final before = _touches[e.pointer];
    if (before == null) return;
    _touches[e.pointer] = e.localPosition;
    if (_two != null) return _twoMove((e.localPosition - before) / _touches.length.toDouble());
    final p = _pending;
    if (p != null) {
      if (p.pointer != e.pointer || (e.localPosition - p.localPosition).distance <= touchSlop) return;
      if (_pendingZoomed) {
        // Zoomed: a moving finger pans the view, all of its move since it landed first.
        _dropPending();
        _panning = e.pointer;
        _viewMoved = true;
        return sink.pan(e.localPosition - p.localPosition);
      }
      _flush();
    }
    if (e.pointer == _panning) return sink.pan(e.localPosition - before);
    if (e.pointer == _pressed) sink.drag(e);
  }

  /// One counted finger of a two-finger gesture moved; the centre moved by [delta]. Taken up at the batch's end.
  void _twoMove(Offset delta) {
    switch (_two) {
      case _Two.undecided:
        _twoBuffer += delta;
        _toDecide = true;
      case _Two.scroll:
        _scrollAcc += delta;
        _scrollPending = true;
      case _Two.pinch:
        _pinchDirty = true;
      case null:
        return;
    }
    _scrollAt = _centre;
    _queueBatch();
  }

  /// At the end of this event batch: decide (if still undecided), then one scroll or one pinch step for the batch.
  void _queueBatch() {
    if (_batchQueued) return;
    _batchQueued = true;
    final batch = _batch;
    scheduleMicrotask(() {
      if (batch != _batch) return;
      _batchQueued = false;
      if (_two == _Two.undecided && _toDecide) _decide();
      if (_scrollPending) {
        _scrollPending = false;
        final d = _scrollAcc;
        _scrollAcc = Offset.zero;
        sink.scroll(_scrollAt, d);
      }
      _pinchStep();
    });
  }

  /// An undecided two-finger gesture, from where its fingers are now: the centre moved past [twoTapSlop] → a scroll
  /// (T3); else the fingers' distance changed by more than [pinchSlop] → a pinch. Either way the move held back so far
  /// goes out with it.
  void _decide() {
    _toDecide = false;
    if (_touches.isEmpty) return;
    if ((_centre - _twoStart).distance > twoTapSlop) {
      _two = _Two.scroll;
      _scrollAcc += _twoBuffer;
      _scrollPending = true;
    } else if (zoomable && _touches.length > 1 && _pinchDistanceChange() > pinchSlop) {
      _two = _Two.pinch;
      _pinchZoom = zoom();
      _pinchCentre = _twoStart; // the first pan is the centre's whole move so far
      _pinchDirty = true;
      _viewMoved = true;
    } else {
      return;
    }
    _twoMoved = true;
    _twoBuffer = Offset.zero;
  }

  /// The two counted fingers' distance now.
  double get _distance {
    final f = _touches.values.take(2).toList();
    return (f[0] - f[1]).distance;
  }

  /// How far that distance is from where it started.
  double _pinchDistanceChange() => (_distance - _pinchDistance).abs();

  /// The pinch so far: the zoom from the fingers' distance (two fingers still on), and the pan from the centre.
  void _pinchStep() {
    if (!_pinchDirty || _touches.isEmpty) return;
    _pinchDirty = false;
    final centre = _centre;
    if (_touches.length > 1) sink.zoom(_pinchZoom * _distance / math.max(_pinchDistance, 1), centre);
    sink.pan(centre - _pinchCentre);
    _pinchCentre = centre;
  }

  void up(PointerEvent e) {
    // Before the centre jumps to the fingers left: decide from this batch's moves not yet taken up (a right tap needs
    // to know), and send a pinch's step for them.
    if (_two == _Two.undecided && _toDecide && _touches.containsKey(e.pointer)) _decide();
    if (_two == _Two.pinch && _touches.containsKey(e.pointer)) {
      _pinchStep();
      _touches.remove(e.pointer);
      if (_touches.isNotEmpty) _pinchCentre = _centre;
    } else {
      _touches.remove(e.pointer);
    }
    if (_two != null) {
      if (_touches.isNotEmpty) return;
      _two = null; // T4
      if (!_twoMoved && e is PointerUpEvent && e.timeStamp - _twoAt <= twoTapTime) sink.rightTap(_twoStart);
      _settle();
      return;
    }
    final p = _pending;
    if (p?.pointer == e.pointer) {
      if (e is PointerCancelEvent) return _dropPending(); // T6
      _flush();
      if (_pressed != e.pointer) return; // the sink pressed nothing: nothing to release
      _pressed = null;
      return sink.release(p!.localPosition, e); // a tap: up where it landed, the jitter never reached A
    }
    if (e.pointer == _panning) {
      _panning = null;
      return _settle();
    }
    if (e.pointer == _pressed) {
      _pressed = null;
      sink.release(e.localPosition, e);
    }
  }

  void _settle() {
    if (!_viewMoved || _touches.isNotEmpty) return;
    _viewMoved = false;
    sink.settled();
  }

  void panZoomStart(PointerPanZoomStartEvent e) {
    _padZoom = zoom();
    _padZoomed = false;
  }

  /// Only the scale: the pan part stays the widget's (a scroll).
  void panZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (!zoomable || e.scale == 1) return;
    _padZoomed = true;
    sink.zoom(_padZoom * e.scale, e.localPosition);
  }

  void panZoomEnd(PointerPanZoomEndEvent e) {
    if (!_padZoomed) return;
    _padZoomed = false;
    sink.settled();
  }

  /// Drops everything in flight and emits nothing; fingers still down are ignored until they lift.
  void reset() {
    _dropPending();
    _touches.clear();
    _pressed = null;
    _panning = null;
    _two = null;
    _twoBuffer = Offset.zero;
    _viewMoved = false;
    _scrollAcc = Offset.zero;
    _scrollPending = false;
    _pinchDirty = false;
    _batchQueued = false;
    _toDecide = false;
    _padZoomed = false;
    _batch++;
  }

  void dispose() => reset();
}
