// The remote window's picture on the stage: the runner's texture, letterboxed. Presses, drags,
// wheels and trackpad scrolls on it go to A; it holds the keys whenever nothing else wants them,
// without a press. On a touchscreen a two-finger swipe scrolls A (P3, docs/superpowers/specs/2026-11-13-rapp-touch-scroll-design.md).
// On an iPad two fingers pinch-zoom the picture on B; A is told only which part of the window shows
// (docs/superpowers/specs/2026-11-18-rapp-pinch-zoom-design.md §6).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../platform_caps.dart' show pinchZoom;
import '../ui/controls.dart';
import '../ui/keep_focus.dart';
import '../ui/main_state.dart';
import '../ui/rule_snack.dart';
import '../ui/tokens.dart';
import 'focus_gray.dart';
import 'geometry.dart';
import 'pointer.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'touch_gestures.dart';
import 'window_tabs.dart';
import 'zoom_view.dart';

class Picture extends StatefulWidget {
  const Picture({
    super.key,
    required this.state,
    required this.session,
    required this.window,
    this.frozen = false,
    this.keyboard = 0,
  });

  /// Where focus and input go: `state.port`, `state.focusPicture`.
  final MainState state;
  final RemoteSession session;
  final RemoteWindow window;

  /// Offline: the last frame stays, and nothing reaches the port.
  final bool frozen;

  /// How far the soft keyboard reaches up over the stage's bottom: a zoomed view can go up over it, and
  /// what it covers is not seen.
  final double keyboard;

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

class _PictureState extends State<Picture> implements TouchSink {
  final _focus = FocusNode();
  late final _clicks = ClickCounter(widget.state.doubleClick);

  /// From the last layout: the window content's rect on the stage (zoomed), and where a press on it counts:
  /// the texture's part, or over the base picture all of the content on the stage.
  Rect _fit = Rect.zero;
  Rect _pic = Rect.zero;

  /// From the last layout: the content's rect at z 1, the stage's size, the keyboard's reach and the
  /// window's content size. Zoomed, a change of any of them shows another part of the window: A is told.
  Rect _fit1 = Rect.zero;
  Size _stage = Size.zero;
  double _keyboard = 0;
  Size _content = Size.zero;

  /// The shown window's zoom (its session keeps it), and when A is told what of it shows: 150 ms after the
  /// view stopped moving, and after the next layout once the window or session changed.
  late ZoomView _zoom;
  Timer? _settleTimer;
  bool _viewDue = true;
  static const _settleDelay = Duration(milliseconds: 150);

  /// The button held since a press on the picture (`left|right`), the pointer that pressed it,
  /// and that press's click count.
  String? _button;
  int? _buttonPointer;
  int _count = 1;

  /// Touch (P3): fingers on the picture, turned into presses, drags, scrolls and right taps (T1–T8).
  late final _touch = TouchGestures(sink: this, zoom: () => _zoom.z, inside: _inside, zoomable: pinchZoom);

  bool _inside(Offset p) {
    final t = _at(p);
    return t.usable && t.pic.contains(p);
  }

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

  /// The window the held button went down on, and where it was last sent.
  _Target? _held;
  Offset _heldAt = Offset.zero;

  void _mouse(String kind, String button, Offset local, _Target t, {Object? sid}) {
    if (widget.frozen) return;
    if (kind == 'down' || kind == 'drag') _heldAt = local;
    final p = toRemote(local, t.fit, t.win);
    widget.state.port?.mouse(sid ?? _sid, t.win.id, kind, button, p.dx, p.dy, _count);
  }

  void _scroll(Offset local, Offset delta) {
    if (widget.frozen) return;
    final t = _at(local);
    if (!t.usable || !t.pic.contains(local)) return;
    final p = toRemote(local, t.fit, t.win);
    final d = scrollScaleToRemote(delta, t.fit, contentSize(t.win));
    widget.state.port?.scroll(_sid, t.win.id, p.dx, p.dy, d.dx, d.dy);
  }

  void _down(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.touch) return _touch.down(e);
    _press(e);
  }

  @override
  bool press(PointerDownEvent e) => _press(e);

  bool _press(PointerDownEvent e) {
    final bit = e.buttons & kPrimaryButton != 0
        ? kPrimaryButton
        : e.buttons & kSecondaryButton != 0
        ? kSecondaryButton
        : 0;
    final t = _at(e.localPosition);
    final marking = widget.state.markingInput == _sid;
    if (!t.usable || !t.pic.contains(e.localPosition)) {
      // The letterbox is outside the picture: like the top bar, a press there takes focus away.
      if (marking) widget.state.cancelMarkInput();
      widget.state.blurPicture();
      return false;
    }
    if (marking) {
      // 「标记输入区」: this click is the mark, A never sees it.
      if (bit == kPrimaryButton && identical(t.win, widget.window) && widget.session.isMain(t.win.id)) {
        final p = toRemote(e.localPosition, t.fit, t.win);
        widget.state.markInputAt(Offset(p.dx, p.dy - t.win.titleBar), contentSize(t.win));
      } else {
        widget.state.cancelMarkInput();
      }
      return false;
    }
    if (bit == 0 || _button != null) return false;
    _focus.requestFocus();
    widget.state.focusPicture(_sid);
    _button = bit == kPrimaryButton ? 'left' : 'right';
    _buttonPointer = e.pointer;
    _held = t;
    _count = _clicks.down(e.localPosition, e.timeStamp, bit);
    _mouse('down', _button!, e.localPosition, t);
    return true;
  }

  void _move(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch) return _touch.move(e);
    drag(e);
  }

  @override
  void drag(PointerMoveEvent e) {
    final b = _button, t = _held;
    if (b == null || t == null || !t.usable || e.pointer != _buttonPointer) return;
    _mouse('drag', b, clampTo(e.localPosition, t.fit), t);
  }

  void _up(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch) return _touch.up(e);
    release(e.localPosition, e);
  }

  @override
  void release(Offset at, PointerEvent e) {
    final b = _button, t = _held;
    if (b == null || t == null || e.pointer != _buttonPointer) return;
    _button = null;
    _buttonPointer = null;
    _held = null;
    if (t.usable) _mouse('up', b, clampTo(at, t.fit), t);
  }

  @override
  void scroll(Offset centre, Offset delta) => _scroll(centre, panToRemote(delta));

  /// T7: a second finger landed on the picture takes the keys.
  @override
  void twoDown(Offset centre) {
    if (!_inside(centre)) return;
    _focus.requestFocus();
    widget.state.focusPicture(_sid);
  }

  /// The view moves on B only; A hears of it once it stops ([settled]).
  @override
  void pan(Offset delta) {
    _settleTimer?.cancel();
    if (_fit1.isEmpty) return;
    _zoom.panBy(delta, _fit1, _stage, keyboard: widget.keyboard);
  }

  @override
  void zoom(double z, Offset focal) {
    _settleTimer?.cancel();
    if (_fit1.isEmpty) return;
    // A pinch back to where it started lands on exactly 1 (not a hair above it): unzoomed again.
    _zoom.zoomTo((z - 1).abs() < 1e-9 ? 1 : z, focal, _fit1, _stage, keyboard: widget.keyboard);
  }

  @override
  void settled() {
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDelay, _sendView);
  }

  /// Tells A the part of the window seen now: the stage above the keyboard, on the zoomed content, in A's
  /// content points (at z 1: the whole window).
  void _sendView() {
    _settleTimer?.cancel();
    if (!mounted || _fit.isEmpty) return;
    final win = _win, c = contentSize(win), z = _fit;
    final s = Rect.fromLTWH(0, 0, _stage.width, math.max(0.0, _stage.height - widget.keyboard)).intersect(z);
    if (s.width <= 0 || s.height <= 0) return;
    final seen = Rect.fromLTRB(
      (s.left - z.left) / z.width * c.width,
      (s.top - z.top) / z.height * c.height,
      (s.right - z.left) / z.width * c.width,
      (s.bottom - z.top) / z.height * c.height,
    );
    widget.session.view.settled(win.id, seen, c, _zoom.z);
  }

  void _zoomed() {
    if (mounted) setState(() {});
  }

  /// T8: a quick two-finger tap is a right click where the two fingers landed (not in the letterbox).
  @override
  void rightTap(Offset at) {
    final t = _at(at);
    if (!t.usable || !t.pic.contains(at)) return;
    _count = 1;
    _mouse('down', 'right', at, t);
    _mouse('up', 'right', at, t);
  }

  void _hover(PointerHoverEvent e) {
    // Only menus and popovers (an address-bar list) track the pointer without a press.
    final t = _at(e.localPosition);
    if ((t.win.kind != WindowKind.menu && t.win.kind != WindowKind.popover) ||
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

  void _pan(PointerPanZoomUpdateEvent e) {
    _touch.panZoomUpdate(e);
    _scroll(e.localPosition, panToRemote(e.localPanDelta));
  }

  @override
  void initState() {
    super.initState();
    _zoom = widget.session.zoomOf(widget.window.id)..addListener(_zoomed);
    widget.session.composer.addListener(_settleSoon);
    FocusManager.instance.addListener(_settleSoon);
  }

  bool _settleQueued = false;

  /// After this frame: the keys come (back) to A unless something else wants them.
  void _settleSoon() {
    if (_settleQueued) return;
    _settleQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleQueued = false;
      _settle();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// The app window holds the keys whenever nothing else does: not the writing panel (its editor,
  /// or a press on it while it is open), not another text field, a dialog or menu above the stage,
  /// nor an open corner list. So it never needs a click to take them.
  void _settle() {
    if (!mounted || widget.frozen) return;
    final s = widget.state, rs = widget.session;
    if (s.pictureFocused != null || s.overview || s.corner != null || s.markingInput != null) return;
    if (s.currentRemote?.sid != _sid || rs.detached) return;
    final c = rs.composer;
    if (c.editorFocused || (c.open && s.panelHolds == _sid)) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final f = FocusManager.instance.primaryFocus;
    if (f != null && f != _focus && f.context?.findAncestorStateOfType<EditableTextState>() != null) return;
    s.focusPicture(_sid);
  }

  @override
  void didUpdateWidget(Picture old) {
    super.didUpdateWidget(old);
    if (!old.frozen && widget.frozen) {
      // Gestures in flight at the drop end here: nothing more reaches the port.
      _touch.reset();
      _button = null;
      _buttonPointer = null;
      _held = null;
    }
    if (!identical(old.session.composer, widget.session.composer)) {
      old.session.composer.removeListener(_settleSoon);
      widget.session.composer.addListener(_settleSoon);
    }
    // A held-back press belongs to the window it landed on; never send it to another.
    if (old.window.id != widget.window.id || old.session.sid != widget.session.sid) _touch.dropPending();
    if (old.window.id != widget.window.id || !identical(old.session, widget.session)) {
      _zoom.removeListener(_zoomed);
      _zoom = widget.session.zoomOf(widget.window.id)..addListener(_zoomed);
      _settleTimer?.cancel();
      // The old session's A shows its whole window again; the window shown now gets its own view (a
      // reconnect's fresh session took the zoom over without telling A).
      if (!identical(old.session, widget.session)) old.session.view.unlimited();
      _viewDue = true;
    }
    // A held button belongs to its session: release it there now, or A keeps it down.
    final b = _button, t = _held;
    if (old.session.sid != widget.session.sid && b != null && t != null) {
      _button = null;
      _buttonPointer = null;
      _held = null;
      if (t.usable) _mouse('up', b, _heldAt, t, sid: old.session.sid);
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _zoom.removeListener(_zoomed);
    // Off the stage (全景, another screen): A's thumbnails want the whole window.
    widget.session.view.unlimited();
    widget.session.composer.removeListener(_settleSoon);
    FocusManager.instance.removeListener(_settleSoon);
    _touch.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A × at a sheet's or popover's top-right corner (they have no close button): Esc on A.
  Widget _popupClose(RappTokens t, _Target p, Size stage) {
    const d = 28.0;
    final left = (p.pic.right - d / 2).clamp(0.0, (stage.width - d).clamp(0.0, double.infinity));
    final top = (p.pic.top - d / 2).clamp(0.0, (stage.height - d).clamp(0.0, double.infinity));
    return Positioned(
      left: left,
      top: top,
      width: d,
      height: d,
      child: Tooltip(
        message: '关闭这个弹出窗口（给远端发 Esc）',
        child: Semantics(
          button: true,
          label: '关闭弹出窗口',
          excludeSemantics: true,
          child: Material(
            key: ValueKey('popup-close-${p.win.id}'),
            color: t.accent,
            shape: const CircleBorder(),
            elevation: 2,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => widget.state.closeWindow(p.win.id),
              onSecondaryTapUp: (e) => _popupMenu(e.globalPosition, p.win.id),
              onLongPress: () => _popupMenu(_global(left + d / 2, top + d / 2), p.win.id),
              child: Icon(Icons.close, size: 16, color: t.accentInk),
            ),
          ),
        ),
      ),
    );
  }

  Offset _global(double x, double y) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? Offset(x, y) : box.localToGlobal(Offset(x, y));
  }

  /// Right-click (or long-press) on a popup's ×: 「隐藏这类窗口」 closes this one and hides the
  /// ones like it from now on (a window rule of the app, with 撤销).
  Future<void> _popupMenu(Offset at, int window) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final pick = await showRappMenu<String>(
      context,
      position: menuAt(context, at),
      items: const [RappMenuItem(value: 'hide', label: '隐藏这类窗口')],
    );
    if (pick != 'hide' || !mounted) return;
    final s = widget.state;
    final undo = s.hideLike(window);
    if (undo == null) return;
    s.closeWindow(window);
    if (messenger != null) ruleSnack(messenger, '已隐藏这类弹出窗口，可在 app 配置里改', undo);
  }

  Widget? _inputMark(RappTokens t, RemoteWindow win, Rect fit) => _inputMarkAt(t, widget.session, win, fit);

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final win = widget.window;
    final focused = widget.state.pictureFocused == _sid;
    if (!focused && !widget.frozen) _settleSoon();
    if (focused && !_focus.hasFocus) {
      // The keys went to A without a press (Ctrl+Enter from the editor): Flutter's focus follows,
      // unless the writing panel's editor still holds the caret (this assumes the editor's unfocus
      // has landed: composerKey's releaseFocus unfocuses in a microtask, before this post-frame callback).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.state.pictureFocused == _sid &&
            !_focus.hasFocus &&
            !widget.session.composer.editorFocused) {
          _focus.requestFocus();
        }
      });
    }
    return LayoutBuilder(
      builder: (context, c) {
        final stage = c.biggest, content = contentSize(win);
        // Rotation, Split View, a fold, the keyboard or A's resize: settled like a pan (a send due anyway wins).
        if (_zoom.z > 1 && !_viewDue && (stage != _stage || widget.keyboard != _keyboard || content != _content)) {
          settled();
        }
        _fit1 = fitRect(content, stage);
        _stage = stage;
        _keyboard = widget.keyboard;
        _content = content;
        final zfit = _zoom.zfit(_fit1, stage, keyboard: widget.keyboard);
        final pic = pictureRect(zfit, win.visible);
        _fit = zfit;
        if (_viewDue) {
          _viewDue = false;
          WidgetsBinding.instance.addPostFrameCallback((_) => _sendView());
        }
        final base = win.baseTexture;
        final backdrop = _zoom.backdrop && base != null && win.visible != _whole && !zfit.isEmpty;
        final onStage = Offset.zero & stage;
        // Zoomed, the base picture shows the window where the live one does not reach (yet): presses there go
        // to A as well.
        _pic = backdrop ? zfit.intersect(onStage) : pic;
        final focusRect = _within(pic.inflate(1), onStage);
        final markRect = _within(pic.inflate(2), onStage);
        final popups = <_Target>[];
        if (zfit.width > 0 && zfit.height > 0) {
          for (final p in popupsFor(widget.session.shown, win.id)) {
            final frame = popupRect(p, win, zfit);
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
        return KeepFocus(child: Focus(
          focusNode: _focus,
          canRequestFocus: !widget.frozen,
          onKeyEvent: (_, event) => widget.frozen
              ? KeyEventResult.ignored
              : widget.state.port?.handleKeyEvent(_sid, event) == true
              ? KeyEventResult.handled
              : KeyEventResult.ignored,
          onFocusChange: (hasFocus) {
            if (!hasFocus && widget.state.pictureFocused == _sid) {
              widget.state.blurPicture();
            }
          },
          child: ClipRect(child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: widget.frozen,
                  child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            onPointerHover: _hover,
            onPointerSignal: _signal,
            onPointerPanZoomStart: _touch.panZoomStart,
            onPointerPanZoomUpdate: _pan,
            onPointerPanZoomEnd: _touch.panZoomEnd,
            child: ColoredBox(
              color: t.bg,
              child: Stack(
                children: [
                  // Zoomed: the whole window's last low-res picture under the live part, for where the live
                  // one does not reach (yet).
                  if (backdrop) Positioned.fromRect(rect: zfit, child: Texture(textureId: base)),
                  Positioned.fromRect(
                    rect: pic,
                    child: windowSurface(win),
                  ),
                  // 智能: everything outside A's focus panes in gray. Only for the window A says
                  // has the focus, and never without a rect (nothing known: nothing gray).
                  Positioned.fromRect(
                    rect: pic,
                    child: ListenableBuilder(
                      listenable: widget.session,
                      builder: (_, _) {
                        final f = widget.session.focus;
                        if (f == null || f.window != win.id || f.rects.isEmpty || pic.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return focusGray(pic.size, frameColor: t.on, [
                          for (final r in f.rects) fromRemoteRect(r, zfit, win).shift(-pic.topLeft),
                        ]);
                      },
                    ),
                  ),
                  if (focused && focusRect != null)
                    // 1px outside the picture, kept on the stage when the picture fills it.
                    Positioned.fromRect(
                      rect: focusRect,
                      child: IgnorePointer(
                        key: const Key('picture-focus'),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: t.on),
                          ),
                        ),
                      ),
                    ),
                  ?_inputMark(t, win, zfit),
                  if (widget.state.markingInput == _sid && markRect != null)
                    Positioned.fromRect(
                      rect: markRect,
                      child: IgnorePointer(
                        key: const Key('picture-marking'),
                        child: DecoratedBox(
                          decoration: BoxDecoration(border: Border.all(color: t.accent, width: 2)),
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
                ),
              ),
              // Above the Listener, not in it: a press on a × never reaches A as a click.
              if (!widget.frozen)
                for (final p in _popups)
                  if (p.win.kind == WindowKind.sheet || p.win.kind == WindowKind.popover)
                  _popupClose(t, p, c.biggest),
            ],
          )),
        ));
      },
    );
  }
}

const _whole = Rect.fromLTWH(0, 0, 1, 1);

/// [r] cut to [stage]; null when nothing of it is on the stage (a zoomed picture panned away).
Rect? _within(Rect r, Rect stage) {
  final i = r.intersect(stage);
  return i.width > 0 && i.height > 0 ? i : null;
}

/// The marked input box: a small ring on the main window's picture, where a send clicks first.
Widget? _inputMarkAt(RappTokens t, RemoteSession session, RemoteWindow win, Rect fit) {
  final p = session.profile.input;
  if (p == null || !session.isMain(win.id) || fit.width <= 0 || fit.height <= 0) return null;
  final size = contentSize(win);
  if (size.width <= 0 || size.height <= 0) return null;
  final o = p.inContent(size);
  final at = Offset(fit.left + o.dx / size.width * fit.width, fit.top + o.dy / size.height * fit.height);
  const r = 7.0;
  return Positioned(
    left: at.dx - r,
    top: at.dy - r,
    width: 2 * r,
    height: 2 * r,
    child: IgnorePointer(
      key: const Key('input-mark'),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: t.accent, width: 2),
          color: t.accent.withValues(alpha: 0.25),
        ),
      ),
    ),
  );
}

/// Shared live/retained surface for native textures and Linux image frames.
Widget windowSurface(RemoteWindow window) {
  final frames = window.frames;
  if (frames != null) {
    return RepaintBoundary(child: ValueListenableBuilder<WindowFrame?>(
      valueListenable: frames,
      builder: (_, frame, _) => frame == null ? const SizedBox.shrink() :
          CustomPaint(painter: _FramePainter(frame.image, frame.source)),
    ));
  }
  return window.image != null
      ? CustomPaint(painter: _FramePainter(window.image!, window.source!))
      : Texture(textureId: window.texture!);
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
