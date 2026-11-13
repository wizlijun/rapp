// The remote window's picture on the stage: the runner's texture, letterboxed. Presses, drags,
// wheels and trackpad scrolls on it go to A; a press gives it keyboard focus. On a touchscreen a
// two-finger swipe scrolls A (P3, docs/superpowers/specs/2026-11-13-rapp-touch-scroll-design.md).
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'geometry.dart';
import 'pointer.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'window_tabs.dart';

class Picture extends StatefulWidget {
  const Picture({
    super.key,
    required this.state,
    required this.session,
    required this.window,
    this.hole,
  });

  /// Where focus and input go: `state.port`, `state.focusPicture`.
  final MainState state;
  final RemoteSession session;
  final RemoteWindow window;

  /// Receives the texture's global rect (R25), so the IRON MAN grid can leave it alone.
  final PictureHole? hole;

  @override
  State<Picture> createState() => _PictureState();
}

/// Where a pointer event goes: the main window or one popup, with that window's own fit.
class _Target {
  const _Target(this.win, this.fit, this.pic);
  final RemoteWindow win;
  final Rect fit;
  final Rect pic;
  bool get usable => fit.width > 0 && fit.height > 0;
}

class _PictureState extends State<Picture> {
  final _tex = GlobalKey();
  final _focus = FocusNode();
  late final _clicks = ClickCounter(widget.state.doubleClick);

  /// From the last layout: the window content's rect on the stage, and the texture's part of it.
  Rect _fit = Rect.zero;
  Rect _pic = Rect.zero;

  /// The button held since a press on the picture (`left|right`), the pointer that pressed it,
  /// and that press's click count.
  String? _button;
  int? _buttonPointer;
  int _count = 1;

  /// Touch (P3): where each finger on the picture is now; a first finger's press not yet sent
  /// (T1); and whether the fingers are scrolling (until all are up, T4).
  final _touches = <int, Offset>{};
  PointerDownEvent? _pending;
  Timer? _pendingTimer;
  bool _touchScroll = false;

  static const _touchSlop = 8.0;
  static const _touchHold = Duration(milliseconds: 150);

  RemoteWindow get _win => widget.window;
  Object get _sid => widget.session.sid;

  /// From the last layout: the popups over the window, topmost first.
  List<_Target> _popups = const [];

  /// The popup under [local], else the main window.
  _Target _at(Offset local) {
    for (final p in _popups) {
      if (p.usable && p.pic.contains(local)) return p;
    }
    return _Target(_win, _fit, _pic);
  }

  /// The window the held button went down on.
  _Target? _held;

  void _mouse(String kind, String button, Offset local, _Target t) {
    final p = toRemote(local, t.fit, t.win);
    widget.state.port?.mouse(_sid, t.win.id, kind, button, p.dx, p.dy, _count);
  }

  void _scroll(Offset local, Offset delta) {
    final t = _at(local);
    if (!t.usable || !t.pic.contains(local)) return;
    final p = toRemote(local, t.fit, t.win);
    widget.state.port?.scroll(_sid, t.win.id, p.dx, p.dy, delta.dx, delta.dy);
  }

  void _down(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.touch) return _touchDown(e);
    _press(e);
  }

  void _touchDown(PointerDownEvent e) {
    if (_touchScroll) return; // T5: not counted, its moves and lift are ignored
    _touches[e.pointer] = e.localPosition;
    if (_pending != null || (_button == null && _touches.length > 1)) {
      // T1: a second finger while the first is held back (or rests in the letterbox, or stayed
      // after a press it was ignored for) — scroll; a held-back press never happened.
      _dropPending();
      _touchScroll = true;
      if (_at(_centre).pic.contains(_centre)) {
        _focus.requestFocus();
        widget.state.focusPicture(_sid); // T7
      }
      return;
    }
    if (_button != null) return; // T2
    final t = _at(e.localPosition);
    if (!t.usable || !t.pic.contains(e.localPosition)) return _press(e); // the letterbox: blurs now
    _pending = e;
    _pendingTimer = Timer(_touchHold, _flush);
  }

  /// Sends the held-back touch press (T1).
  void _flush() {
    final e = _pending;
    _dropPending();
    if (e != null) _press(e);
  }

  void _dropPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pending = null;
  }

  Offset get _centre => _touches.values.reduce((a, b) => a + b) / _touches.length.toDouble();

  void _press(PointerDownEvent e) {
    final bit = e.buttons & kPrimaryButton != 0
        ? kPrimaryButton
        : e.buttons & kSecondaryButton != 0
        ? kSecondaryButton
        : 0;
    final t = _at(e.localPosition);
    if (!t.usable || !t.pic.contains(e.localPosition)) {
      // The letterbox is outside the picture: like the top bar, a press there takes focus away.
      widget.state.blurPicture();
      return;
    }
    if (bit == 0 || _button != null) return;
    _focus.requestFocus();
    widget.state.focusPicture(_sid);
    _button = bit == kPrimaryButton ? 'left' : 'right';
    _buttonPointer = e.pointer;
    _held = t;
    _count = _clicks.down(e.localPosition, e.timeStamp, bit);
    _mouse('down', _button!, e.localPosition, t);
  }

  void _move(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      final before = _touches[e.pointer];
      if (before == null) return;
      _touches[e.pointer] = e.localPosition;
      if (_touchScroll) {
        // T3: the centre moves by this finger's move over the number of fingers.
        return _scroll(_centre, panToRemote((e.localPosition - before) / _touches.length.toDouble()));
      }
      final p = _pending;
      if (p != null) {
        if (p.pointer != e.pointer || (e.localPosition - p.localPosition).distance <= _touchSlop) return;
        _flush();
      }
    }
    final b = _button, t = _held;
    if (b == null || t == null || !t.usable || e.pointer != _buttonPointer) return;
    _mouse('drag', b, clampTo(e.localPosition, t.fit), t);
  }

  void _up(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      _touches.remove(e.pointer);
      if (_touchScroll) {
        if (_touches.isEmpty) _touchScroll = false; // T4
        return;
      }
    }
    var at = e.localPosition;
    if (e.kind == PointerDeviceKind.touch) {
      final p = _pending;
      if (p?.pointer == e.pointer) {
        if (e is PointerCancelEvent) return _dropPending(); // T6
        at = p!.localPosition; // a tap: up where it landed, the jitter never reached A
        _flush();
      }
    }
    final b = _button, t = _held;
    if (b == null || t == null || e.pointer != _buttonPointer) return;
    _button = null;
    _buttonPointer = null;
    _held = null;
    if (t.usable) _mouse('up', b, clampTo(at, t.fit), t);
  }

  void _hover(PointerHoverEvent e) {
    // Only menus track the pointer without a press.
    final t = _at(e.localPosition);
    if (t.win.kind != WindowKind.menu ||
        !t.usable ||
        !t.pic.contains(e.localPosition)) {
      return;
    }
    _mouse('move', 'left', e.localPosition, t);
  }

  void _signal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      _scroll(e.localPosition, wheelToRemote(e.scrollDelta));
    }
  }

  void _pan(PointerPanZoomUpdateEvent e) =>
      _scroll(e.localPosition, panToRemote(e.localPanDelta));

  void _report() {
    final h = widget.hole;
    if (h == null || !mounted) return;
    final box = _tex.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (h.owns(this, r)) return;
    h.claim(this, r);
  }

  @override
  void didUpdateWidget(Picture old) {
    super.didUpdateWidget(old);
    // A held-back press belongs to the window it landed on; never send it to another.
    if (old.window.id != widget.window.id || old.session.sid != widget.session.sid) _dropPending();
  }

  @override
  void dispose() {
    _dropPending();
    final h = widget.hole;
    if (h != null) {
      // Not while the tree is being torn down; and only what this picture itself reported.
      SchedulerBinding.instance.addPostFrameCallback((_) => h.release(this));
    }
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final win = widget.window;
    SchedulerBinding.instance.addPostFrameCallback((_) => _report());
    final focused = widget.state.pictureFocused == _sid;
    return LayoutBuilder(
      builder: (context, c) {
        final fit = fitRect(contentSize(win), c.biggest);
        final pic = pictureRect(fit, win.visible);
        _fit = fit;
        _pic = pic;
        final popups = <_Target>[];
        if (fit.width > 0 && fit.height > 0) {
          for (final p in popupsFor(widget.session.windows, win.id)) {
            final frame = popupRect(p, win, fit);
            if (frame.width <= 0 || frame.height <= 0 || p.rect.width <= 0) {
              continue;
            }
            // The popup's own content: below its title bar, if it has one.
            final k = frame.width / p.rect.width;
            final content = Rect.fromLTRB(
              frame.left,
              frame.top + p.titleBar * k,
              frame.right,
              frame.bottom,
            );
            popups.add(_Target(p, content, pictureRect(content, p.visible)));
          }
        }
        _popups = popups;
        return Focus(
          focusNode: _focus,
          onKeyEvent: (_, event) =>
              widget.state.port?.handleKeyEvent(_sid, event) == true
              ? KeyEventResult.handled
              : KeyEventResult.ignored,
          onFocusChange: (hasFocus) {
            if (!hasFocus && widget.state.pictureFocused == _sid) {
              widget.state.blurPicture();
            }
          },
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            onPointerHover: _hover,
            onPointerSignal: _signal,
            onPointerPanZoomUpdate: _pan,
            child: ColoredBox(
              color: t.bg,
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: pic,
                    child: windowSurface(win, key: _tex),
                  ),
                  if (focused)
                    // 1px outside the picture, kept on the stage when the picture fills it.
                    Positioned.fromRect(
                      rect: pic.inflate(1).intersect(Offset.zero & c.biggest),
                      child: IgnorePointer(
                        key: const Key('picture-focus'),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: t.on),
                          ),
                        ),
                      ),
                    ),
                  // Behind first, so the first of the table ends up on top.
                  for (final p in _popups.reversed)
                    Positioned.fromRect(rect: p.pic, child: windowSurface(p.win)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shared live/retained surface for native textures and Linux image frames.
Widget windowSurface(RemoteWindow window, {Key? key}) {
  final frames = window.frames;
  if (frames != null) {
    return RepaintBoundary(key: key, child: ValueListenableBuilder<WindowFrame?>(
      valueListenable: frames,
      builder: (_, frame, _) => frame == null ? const SizedBox.shrink() :
          CustomPaint(painter: _FramePainter(frame.image, frame.source)),
    ));
  }
  return window.image != null
      ? CustomPaint(key: key, painter: _FramePainter(window.image!, window.source!))
      : Texture(key: key, textureId: window.texture!);
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.image, this.source);
  final ui.Image image;
  final Rect source;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawImageRect(
    image,
    source,
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.low,
  );
  @override
  bool shouldRepaint(_FramePainter old) =>
      image != old.image || source != old.source;
}
