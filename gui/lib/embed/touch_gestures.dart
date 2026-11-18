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
  /// A finger press now; `e` is the finger's down event.
  void press(PointerDownEvent e);

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

  /// T3: one scroll (or one pinch step) per event batch; [_batch] goes up at every [reset], so a batch queued before
  /// it is dropped.
  Offset _scrollAcc = Offset.zero;
  Offset _scrollAt = Offset.zero;
  bool _scrollQueued = false;
  bool _pinchDirty = false;
  bool _pinchQueued = false;
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
    if (!zoomed && !inside(e.localPosition)) return sink.press(e); // outside: blurs now, holds nothing
    _pending = e;
    _pendingZoomed = zoomed;
    _pendingTimer = Timer(zoomed ? zoomedHold : touchHold, _flush);
  }

  /// Sends the held-back press (T1; zoomed: held still [zoomedHold]).
  void _flush() {
    final e = _pending;
    _dropPending();
    if (e == null) return;
    _pressed = e.pointer;
    sink.press(e);
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

  /// One counted finger of a two-finger gesture moved; the centre moved by [delta].
  void _twoMove(Offset delta) {
    if (_two == _Two.undecided) {
      _twoBuffer += delta;
      final centre = _centre;
      if ((centre - _twoStart).distance > twoTapSlop) {
        _two = _Two.scroll;
      } else if (zoomable && _touches.length > 1 && _pinchDistanceChange() > pinchSlop) {
        _two = _Two.pinch;
        _pinchZoom = zoom();
        _pinchCentre = _twoStart; // the first pan is the centre's whole move so far
        _viewMoved = true;
      } else {
        return;
      }
      _twoMoved = true;
      delta = _twoBuffer;
      _twoBuffer = Offset.zero;
    }
    if (_two == _Two.pinch) return _queuePinch();
    _queueScroll(delta);
  }

  /// The two counted fingers' distance now.
  double get _distance {
    final f = _touches.values.take(2).toList();
    return (f[0] - f[1]).distance;
  }

  /// How far that distance is from where it started.
  double _pinchDistanceChange() => (_distance - _pinchDistance).abs();

  // T3: the fingers' moves of one event batch add up to the centre's move, sent once.
  void _queueScroll(Offset delta) {
    _scrollAcc += delta;
    _scrollAt = _centre;
    if (_scrollQueued) return;
    _scrollQueued = true;
    final batch = _batch;
    scheduleMicrotask(() {
      if (batch != _batch) return;
      _scrollQueued = false;
      final d = _scrollAcc;
      _scrollAcc = Offset.zero;
      sink.scroll(_scrollAt, d);
    });
  }

  void _queuePinch() {
    _pinchDirty = true;
    if (_pinchQueued) return;
    _pinchQueued = true;
    final batch = _batch;
    scheduleMicrotask(() {
      if (batch != _batch) return;
      _pinchQueued = false;
      _pinchStep();
    });
  }

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
    if (_two == _Two.pinch && _touches.containsKey(e.pointer)) {
      _pinchStep(); // this batch's moves so far, before the centre jumps to the fingers left
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
    _scrollQueued = false;
    _pinchDirty = false;
    _pinchQueued = false;
    _padZoomed = false;
    _batch++;
  }

  void dispose() => reset();
}
