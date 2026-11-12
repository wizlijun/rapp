// The remote window's picture on the stage: the runner's texture, letterboxed. Presses, drags,
// wheels and trackpad scrolls on it go to A; a press gives it keyboard focus.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'geometry.dart';
import 'pointer.dart';
import 'remote_session.dart';
import 'session_port.dart';

class Picture extends StatefulWidget {
  const Picture({super.key, required this.state, required this.session, required this.window, this.hole});

  /// Where focus and input go: `state.port`, `state.focusPicture`.
  final MainState state;
  final RemoteSession session;
  final RemoteWindow window;

  /// Receives the texture's global rect (R25), so the IRON MAN grid can leave it alone.
  final ValueNotifier<Rect?>? hole;

  @override
  State<Picture> createState() => _PictureState();
}

class _PictureState extends State<Picture> {
  final _tex = GlobalKey();
  Rect? _mine;
  late final _clicks = ClickCounter(widget.state.doubleClick);

  /// From the last layout: the window content's rect on the stage, and the texture's part of it.
  Rect _fit = Rect.zero;
  Rect _pic = Rect.zero;

  /// The button held since a press on the picture (`left|right`), and that press's click count.
  String? _button;
  int _count = 1;

  RemoteWindow get _win => widget.window;
  Object get _sid => widget.session.sid;

  /// Nothing goes to A while the content has no area (`toRemote` divides by it).
  bool get _usable => _fit.width > 0 && _fit.height > 0;

  void _mouse(String kind, String button, Offset local) {
    final p = toRemote(local, _fit, _win);
    widget.state.port?.mouse(_sid, _win.id, kind, button, p.dx, p.dy, _count);
  }

  void _scroll(Offset local, Offset delta) {
    if (!_usable || !_pic.contains(local)) return;
    final p = toRemote(local, _fit, _win);
    widget.state.port?.scroll(_sid, _win.id, p.dx, p.dy, delta.dx, delta.dy);
  }

  void _down(PointerDownEvent e) {
    final bit = e.buttons & kPrimaryButton != 0
        ? kPrimaryButton
        : e.buttons & kSecondaryButton != 0
            ? kSecondaryButton
            : 0;
    if (bit == 0 || _button != null || !_usable || !_pic.contains(e.localPosition)) return;
    widget.state.focusPicture(_sid);
    _button = bit == kPrimaryButton ? 'left' : 'right';
    _count = _clicks.down(e.localPosition, e.timeStamp, bit);
    _mouse('down', _button!, e.localPosition);
  }

  void _move(PointerMoveEvent e) {
    final b = _button;
    if (b == null || !_usable) return;
    _mouse('drag', b, clampTo(e.localPosition, _fit));
  }

  void _up(PointerEvent e) {
    final b = _button;
    if (b == null) return;
    _button = null;
    if (_usable) _mouse('up', b, clampTo(e.localPosition, _fit));
  }

  void _hover(PointerHoverEvent e) {
    // Only menus track the pointer without a press (Task 9 layers them over the window).
    if (_win.kind != WindowKind.menu || !_usable || !_pic.contains(e.localPosition)) return;
    _mouse('move', 'left', e.localPosition);
  }

  void _signal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) _scroll(e.localPosition, wheelToRemote(e.scrollDelta));
  }

  void _pan(PointerPanZoomUpdateEvent e) => _scroll(e.localPosition, panToRemote(e.localPanDelta));

  void _report() {
    final h = widget.hole;
    if (h == null || !mounted) return;
    final box = _tex.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (r == _mine && h.value == r) return;
    _mine = r;
    h.value = r;
  }

  @override
  void dispose() {
    final h = widget.hole, mine = _mine;
    if (h != null && mine != null) {
      // Not while the tree is being torn down; and not over a newer picture's rect.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (h.value == mine) h.value = null;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final win = widget.window;
    SchedulerBinding.instance.addPostFrameCallback((_) => _report());
    final focused = widget.state.pictureFocused == _sid;
    return LayoutBuilder(builder: (context, c) {
      final fit = fitRect(contentSize(win), c.biggest);
      final pic = pictureRect(fit, win.visible);
      _fit = fit;
      _pic = pic;
      return Listener(
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
          child: Stack(children: [
            Positioned.fromRect(rect: pic, child: Texture(key: _tex, textureId: win.texture!)),
            if (focused)
              // 1px outside the picture, kept on the stage when the picture fills it.
              Positioned.fromRect(
                rect: pic.inflate(1).intersect(Offset.zero & c.biggest),
                child: IgnorePointer(
                  key: const Key('picture-focus'),
                  child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: t.on))),
                ),
              ),
          ]),
        ),
      );
    });
  }
}
