// The stage of a terminal session: draws the pane, asks for the size the stage can show (Z1), scrolls the
// history (H1, H2), selects and copies (C1–C5), opens links (L1) and, with focus, sends the keyboard (K1–K6).
// Fingers mean what they mean on the app picture (the shared recognizer); on an iPad they also pinch-zoom the
// grid, purely on B: bigger cells, panned and clipped. A never hears of the zoom (pinch-zoom spec §6).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../embed/remote_session.dart';
import '../embed/touch_gestures.dart';
import '../embed/voice_key_gate.dart';
import '../embed/zoom_view.dart';
import '../ios_channel.dart';
import '../platform_caps.dart';
import '../ui/keep_focus.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'sgr.dart' show TermLine;
import 'term_keys.dart';
import 'term_layout.dart';
import 'term_model.dart';
import 'term_painter.dart';
import 'term_palette.dart';
import 'term_select.dart';
import 'term_session_port.dart';

/// The grid's font (D2, Z3's default size); no ligatures.
TextStyle termTextStyle(RappTokens t) => TextStyle(
      fontFamily: t.mono,
      fontFamilyFallback: t.monoFallback,
      fontSize: 14,
      color: t.text,
      fontFeatures: const [FontFeature.disable('liga'), FontFeature.disable('calt')],
    );

/// Opens [url] in this computer's browser.
Future<void> openUrl(String url) async {
  try {
    if (caps.systemOpen) {
      await iosChannel.openUrl(url);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', url], mode: ProcessStartMode.detached);
    }
  } catch (_) {
    // No opener: nothing to do.
  }
}

/// Test probe: every key event the terminal's own key handling is given, in order (the gate's flush included).
@visibleForTesting
void Function(KeyEvent e)? debugTermKeySeen;

const _viewPause = Duration(milliseconds: 300);
const _multiClick = Duration(milliseconds: 500);
const _multiClickSlop = 4.0;
const _edgeEvery = Duration(milliseconds: 50);
const _noteFor = Duration(seconds: 3);
const _copiedFor = Duration(seconds: 1);

/// K6: how long a key or text may go without a new screen before the ellipsis shows.
const _echoWait = Duration(milliseconds: 300);

class TermStage extends StatefulWidget {
  const TermStage({
    super.key,
    required this.state,
    required this.session,
    required this.port,
    this.frozen = false,
    this.keyboard = 0,
  });

  final MainState state;
  final RemoteSession session;
  final TermSessionPort port;

  /// A network drop: the picture stays for reading and copying, but no input goes out.
  final bool frozen;

  /// How far the soft keyboard reaches up over the stage's bottom: a zoomed grid can go up over it, and a drag
  /// past its top edge scrolls.
  final double keyboard;

  @override
  State<TermStage> createState() => _TermStageState();
}

typedef _View = ({int window, int cols, int rows, bool fit});

class _TermStageState extends State<TermStage> with SingleTickerProviderStateMixin implements TouchSink {
  final _focus = FocusNode(debugLabel: 'term-stage');
  final _cache = TermRowCache();
  TermModel? _model;

  /// Bumped for every change to what is painted.
  int _ver = 0;

  RappTokens? _tokens;

  /// What the palette and the metrics were made from: the app rebuilds its theme (fresh, equal tokens) on
  /// every MainState change, so they are compared by value, not identity.
  Object? _lookKey;
  late TermPalette _palette;

  /// The metrics at the base size: they set the columns and rows the stage asks for.
  late TermMetrics _metrics;

  /// The metrics the grid is drawn with: the font at the size that fits the pane to the stage. Hit-testing
  /// and scrolling use them too.
  late TermMetrics _drawn;

  /// [_drawn] times the zoom: what the grid is drawn, hit-tested and scrolled with (at z 1, [_drawn] itself).
  late TermMetrics _zoomed;
  TermMetrics? _zoomedFrom;
  double _zoomedZ = 1;

  /// From the last layout: the stage's size, the grid at z 1 ([_drawn]'s cells from the stage's top left), and
  /// where the zoom puts it on the stage.
  Size _stage = Size.zero;
  Rect _fit = Rect.zero;
  Rect _zfit = Rect.zero;

  /// The shown pane's zoom (its session keeps one per window); null before the session has a pane.
  ZoomView? _zoom;
  int? _zoomWindow;

  /// Touch: fingers turned into presses, drags, scrolls and the zoom's pans and pinches (T1–T8).
  late final _touch = TouchGestures(sink: this, zoom: () => _zoom?.z ?? 1, inside: (_) => true, zoomable: pinchZoom);

  /// Metrics measured at other font sizes since the look last changed: measuring on every build is too slow.
  final _sized = <double, TermMetrics>{};
  double _dpr = 1;

  // Size (Z1).
  int _cols = 0, _rows = 0;
  bool _viewQueued = false;
  _View? _sent, _pending;
  Timer? _viewTimer;

  // Trackpad fling (H1).
  late final Ticker _fling;
  FrictionSimulation? _sim;
  VelocityTracker? _velocity;

  // Selection (C1).
  TermSelection? _sel;
  TermPoint? _anchor;
  int _clicks = 0;
  Duration? _lastClick;
  Offset _lastClickAt = Offset.zero;
  int? _dragPointer;
  bool _dragBlock = false;
  Offset _dragAt = Offset.zero;

  /// The drag's top and bottom edges (C1): past them the drag scrolls.
  double _edgeTop = 0, _edgeBottom = 0;
  Timer? _edgeTimer;
  bool _copied = false;
  Timer? _copiedTimer;
  TermSelection? _countedSel;
  int _count = 0;

  // Links (L1).
  List<LinkSpan> _links = const [];
  int _linksVer = -1;
  Offset? _hover;
  bool _hand = false;

  String? _note;
  Timer? _noteTimer;

  // Focus asked for by MainState (`termFocusTick`).
  int _focusSeen = 0;

  // K6: the screen when the latest input went out; null when not waiting for one.
  List<TermLine>? _echoFrom;
  Timer? _echoTimer;
  bool _waiting = false;

  bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  // Hold-to-talk hotkey (macOS): the same gate the app picture uses; off macOS it never runs.
  final _gate = VoiceKeyGate();
  final _gateClock = Stopwatch()..start();
  KeyEvent? _gateHeld;
  Timer? _gateTimer;
  int _gateArmedAt = 0;
  StreamSubscription<Object>? _voiceEnds;

  /// A hotkey press may start voice now: macOS, a voice engine, the panel allowed and not open (it takes the
  /// voice and the keys itself), and the stage has the keyboard.
  bool get _voiceReady =>
      (_mac || defaultTargetPlatform == TargetPlatform.linux) &&
      widget.state.voice != null &&
      widget.session.composerAllowed &&
      !widget.session.composer.open &&
      _focus.hasFocus;

  bool get _gateOn => (_mac || defaultTargetPlatform == TargetPlatform.linux) && widget.state.voice != null;

  @override
  void initState() {
    super.initState();
    _fling = createTicker(_tick);
    widget.session.addListener(_onSession);
    _focus.addListener(_onFocus);
    HardwareKeyboard.instance.addHandler(_onKeys);
    _focusSeen = widget.state.termFocusTick;
    widget.state.addListener(_onState);
    _listenVoiceEnds();
    _bind();
    _bindZoom();
    _focusIfWanted();
  }

  @override
  void didUpdateWidget(TermStage old) {
    super.didUpdateWidget(old);
    if (!identical(old.state, widget.state)) {
      old.state.removeListener(_onState);
      widget.state.addListener(_onState);
      _focusSeen = widget.state.termFocusTick;
      _listenVoiceEnds();
    }
    if (!identical(old.session, widget.session)) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _focusIfWanted();
      // The element is reused for the new session: a hold of the hotkey was on the old one, and ends there.
      _gateTimer?.cancel();
      _gateHeld = null;
      final phase = _gate.handle(VoiceGateInput.resign, ms: _gateMs, ready: false).voice;
      if (phase != null) widget.state.voiceKey(old.session.sid, phase);
    }
    if (!identical(old.session, widget.session) || !identical(old.port, widget.port)) {
      _sent = null;
      _bind();
    }
    if (!identical(old.session, widget.session)) _bindZoom(force: true);
    if (!old.frozen && widget.frozen) {
      // Gestures in flight at the drop end here.
      _touch.reset();
      _release(_dragPointer);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    widget.state.removeListener(_onState);
    HardwareKeyboard.instance.removeHandler(_onKeys);
    _voiceEnds?.cancel();
    _gateTimer?.cancel();
    _unbind();
    _zoom?.removeListener(_onZoom);
    _touch.dispose();
    _fling.dispose();
    _focus.dispose();
    _cache.dispose();
    for (final t in [_viewTimer, _edgeTimer, _copiedTimer, _noteTimer, _echoTimer]) {
      t?.cancel();
    }
    super.dispose();
  }

  // ---- model ----

  void _bind() {
    final m = widget.port.model(widget.session.sid);
    if (identical(m, _model)) return;
    _unbind();
    _model = m;
    _ver++;
    _sel = null;
    _anchor = null;
    _endWait();
    // The port drops a view for a session it has no model of yet: send again now there is one.
    _sent = null;
    if (m != null) {
      m.addListener(_onModel);
      m.onShift = _onShift;
      _takeNote(m);
    }
  }

  void _unbind() {
    final m = _model;
    if (m == null) return;
    m.removeListener(_onModel);
    if (m.onShift == _onShift) m.onShift = null;
    _model = null;
  }

  /// The window or the model may have changed: build again to send the view.
  void _onSession() => setState(() {
        _bind();
        _bindZoom();
      });

  /// Follows the shown pane's zoom; [force]: the session changed, so its zooms are other ones.
  void _bindZoom({bool force = false}) {
    final win = widget.session.currentWindow;
    if (!force && win == _zoomWindow) return;
    // A press held back belongs to the pane it landed on; never press another.
    _touch.dropPending();
    _zoom?.removeListener(_onZoom);
    _zoomWindow = win;
    _zoom = win == null ? null : (widget.session.zoomOf(win)..addListener(_onZoom));
  }

  /// Laid out again: a pan only moves the grid, a new z brings new metrics (and so a repaint) with it.
  void _onZoom() {
    if (mounted) setState(() {});
  }

  void _onShift(int d) {
    final m = _model, s = _sel, a = _anchor;
    if (m == null) return;
    if (s != null) _sel = shifted(s, d, m.lineAt);
    if (a != null) _anchor = TermPoint(a.y - d, a.x);
  }

  void _onModel() {
    final m = _model!;
    final s = _sel;
    // A refresh keeps the selection unless one of its rows changed (C4).
    if (s != null) _sel = shifted(s, 0, m.lineAt);
    if (m.alt) _stopFling();
    // K6: a new screen came; whatever it shows, the input is no longer unanswered.
    if (_echoFrom != null && !identical(m.screen, _echoFrom)) _endWait();
    _takeNote(m);
    widget.port.fetchHistory(widget.session.sid);
    setState(() => _ver++);
  }

  void _takeNote(TermModel m) {
    final n = m.note;
    if (n == null) return;
    // Taken, so the same error coming again shows again.
    m.note = null;
    _showNote(n);
  }

  void _showNote(String n) {
    _note = n;
    _noteTimer?.cancel();
    _noteTimer = Timer(_noteFor, () {
      if (mounted) setState(() => _note = null);
    });
  }

  void _onFocus() {
    // Losing the keyboard interrupts a hold (R7).
    if (!_focus.hasFocus && _gateOn) _gateFeed(VoiceGateInput.resign);
    setState(() => _ver++);
  }

  // ---- hold-to-talk hotkey ----

  void _listenVoiceEnds() {
    _voiceEnds?.cancel();
    _voiceEnds = widget.state.voiceEnds.listen((sid) {
      if (sid == widget.session.sid) _gateFeed(VoiceGateInput.ended);
    });
  }

  int get _gateMs => _gateClock.elapsedMilliseconds;

  /// The gate takes the hotkey setting. A change mid-hold (关, 恢复默认 or a new key recorded) starts the gate
  /// over: the old key's hold timer and held down go, and a recording on it is cancelled.
  void _syncHotkey() {
    final h = widget.state.prefs.voiceHotkey;
    if (h == _gate.hotkey) return;
    _gateTimer?.cancel();
    _gateHeld = null;
    final phase = _gate.setHotkey(h).voice;
    if (phase != null) widget.state.voiceKey(widget.session.sid, phase);
  }

  /// Feeds [i] to the gate and does what it says except passing the event on: the held hotkey down goes to the
  /// terminal first (flush), a pending hotkey arms the hold timer, a phase goes to MainState. Returns the step.
  VoiceGateStep _gateFeed(VoiceGateInput i, {KeyEvent? event, int? ms}) {
    final step = _gate.handle(i, ms: ms ?? _gateMs, ready: _voiceReady);
    if (step.flush) {
      final held = _gateHeld;
      _gateHeld = null;
      _gateTimer?.cancel();
      if (held != null) _termKey(_focus, held);
    }
    if (step.arm && event != null) {
      _gateHeld = event;
      _gateArmedAt = ms ?? _gateMs;
      _gateTimer?.cancel();
      _gateTimer = Timer(Duration(milliseconds: (VoiceKeyGate.holdDelay * 1000).round()), () {
        // The timer is the hold: never earlier than the gate's own delay, whatever the wall clock says.
        final at = math.max(_gateMs, _gateArmedAt + (VoiceKeyGate.holdDelay * 1000).round() + 1);
        _gateFeed(VoiceGateInput.elapsed, ms: at);
      });
    }
    final phase = step.voice;
    if (phase != null) {
      if (phase == VoiceKeyPhase.start) _gateHeld = null;
      widget.state.voiceKey(widget.session.sid, phase);
    }
    return step;
  }

  // ---- focus ----

  /// MainState asked for the keys to come here (`focusPicture`, a terminal opened or switched to).
  void _onState() {
    _syncHotkey();
    if (widget.state.prefs.termFit != (_sent?.fit ?? widget.state.prefs.termFit)) setState(() {});
    final tick = widget.state.termFocusTick;
    if (tick == _focusSeen) return;
    _focusSeen = tick;
    _focusIfWanted();
  }

  /// After the frame: the writing panel's editor lets go of the caret first (`composerKey`).
  void _focusIfWanted() {
    if (widget.state.termFocusSid != widget.session.sid) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.state.termFocusSid == widget.session.sid) _focus.requestFocus();
    });
  }

  // ---- size (Z1) ----

  void _queueView(int cols, int rows) {
    _cols = cols;
    _rows = rows;
    if (_viewQueued) return;
    _viewQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _flushView());
  }

  void _flushView() {
    _viewQueued = false;
    if (!mounted) return;
    final win = widget.session.currentWindow;
    if (win == null || _model == null) return;
    final v = (window: win, cols: _cols, rows: _rows, fit: widget.state.prefs.termFit);
    final sent = _sent;
    if (v == sent) {
      _viewTimer?.cancel();
      _pending = null;
      return;
    }
    // The first view of a pane, and a change of fit, go at once; a new size waits until the stage stops changing.
    if (sent == null || sent.window != win || sent.fit != v.fit) {
      _viewTimer?.cancel();
      _pending = null;
      _sendView(v);
      return;
    }
    if (v == _pending) return;
    _pending = v;
    _viewTimer?.cancel();
    _viewTimer = Timer(_viewPause, () {
      final p = _pending;
      _pending = null;
      if (p != null && mounted && p.window == widget.session.currentWindow) _sendView(p);
    });
  }

  void _sendView(_View v) {
    _sent = v;
    widget.port.view(widget.session.sid, v.window, v.cols, v.rows, fit: v.fit);
  }

  // ---- scrolling (H1, H2) ----

  void _scroll(double rows) {
    final m = _model;
    if (m == null || m.alt || m.screen.isEmpty || rows == 0 || !rows.isFinite) return;
    m.scrollBy(rows);
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (_gateOn) _gateFeed(VoiceGateInput.scroll);
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
      _stopFling();
      _scroll(-(ev as PointerScrollEvent).scrollDelta.dy / _zoomed.cellH);
    });
  }

  // A trackpad's pinch is the recognizer's (the zoom); its pan scrolls, as ever.
  void _onPanStart(PointerPanZoomStartEvent e) {
    _stopFling();
    _touch.panZoomStart(e);
    _velocity = VelocityTracker.withKind(PointerDeviceKind.trackpad);
  }

  void _onPanUpdate(PointerPanZoomUpdateEvent e) {
    _touch.panZoomUpdate(e);
    _velocity?.addPosition(e.timeStamp, e.pan);
    _scroll(e.panDelta.dy / _zoomed.cellH);
  }

  void _onPanEnd(PointerPanZoomEndEvent e) {
    _touch.panZoomEnd(e);
    final m = _model, vt = _velocity;
    _velocity = null;
    if (m == null || vt == null || m.alt) return;
    final v = vt.getVelocity().pixelsPerSecond.dy / _zoomed.cellH;
    if (v.abs() < 1) return;
    _sim = FrictionSimulation(0.135, m.offset, v);
    _fling.start();
  }

  void _tick(Duration elapsed) {
    final m = _model, sim = _sim;
    if (m == null || sim == null) return _stopFling();
    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final before = m.offset;
    _scroll(sim.x(t) - before);
    final stuck = m.offset == before && (m.offset == 0 || m.offset >= m.scrollMax);
    if (sim.isDone(t) || stuck) _stopFling();
  }

  void _stopFling() {
    _sim = null;
    if (_fling.isActive) _fling.stop();
  }

  // ---- selection (C1–C5) ----

  /// The cell under [local] (stage coordinates), clamped into the rows in view.
  TermPoint? _cellAt(Offset local) {
    final m = _model, c = _zoomed;
    if (m == null || m.screen.isEmpty || c.cellW <= 0 || c.cellH <= 0) return null;
    final at = local - _zfit.topLeft;
    final top = (-m.offset).floor();
    final int y = (at.dy / c.cellH - m.offset).floor().clamp(top, math.max(top, m.rows - 1));
    final int x = (at.dx / c.cellW).floor().clamp(0, math.max(0, m.cols - 1));
    return TermPoint(y, x);
  }

  void _setSel(TermSelection? s) {
    _sel = s;
    _copied = false;
  }

  bool get _linkKey => _mac ? HardwareKeyboard.instance.isMetaPressed : HardwareKeyboard.instance.isControlPressed;

  LinkSpan? _linkAt(TermPoint? p) {
    if (p == null) return null;
    for (final l in _links) {
      if (l.y == p.y && p.x >= l.x0 && p.x < l.x1) return l;
    }
    return null;
  }

  void _onDown(PointerDownEvent e) {
    if (_gateOn) _gateFeed(VoiceGateInput.pointer);
    _focus.requestFocus();
    widget.state.blurPicture();
    _stopFling();
    if (e.kind == PointerDeviceKind.touch) return _touch.down(e);
    if (e.buttons != kPrimaryButton) return;
    _pressAt(e.localPosition, e.timeStamp, e.pointer);
  }

  /// A primary press at [local]: a ⌘/Ctrl link opens, else a click (counted) starts or extends a selection.
  /// True when [pointer] now drags it.
  bool _pressAt(Offset local, Duration time, int pointer) {
    final m = _model;
    final p = _cellAt(local);
    if (m == null || p == null) return false;
    final link = _linkKey ? _linkAt(p) : null;
    if (link != null) {
      openUrl(link.url);
      return false;
    }
    final last = _lastClick;
    final again = last != null && time - last <= _multiClick && (local - _lastClickAt).distance <= _multiClickSlop;
    _clicks = again ? (_clicks == 3 ? 1 : _clicks + 1) : 1;
    _lastClick = time;
    _lastClickAt = local;
    _dragPointer = pointer;
    _dragAt = local;
    _dragBlock = HardwareKeyboard.instance.isAltPressed;
    final keys = HardwareKeyboard.instance;
    switch (_clicks) {
      case 1:
        final a = _anchor;
        // Shift extends from the anchor: the selection's, or a plain click's that has not selected yet.
        if (keys.isShiftPressed && a != null) {
          _setSel(select(a, p, m.lineAt, block: _sel?.block ?? _dragBlock));
        } else {
          _anchor = p;
          _setSel(null);
        }
      case 2:
        final line = m.lineAt(p.y);
        if (line != null) {
          final (start, end) = wordAt(line, p.x);
          _anchor = TermPoint(p.y, start);
          _setSel(select(_anchor!, TermPoint(p.y, end - 1), m.lineAt));
        }
      default:
        final (a, b) = lineAtPoint(p.y, m.wrappedAt, m.lineAt);
        _anchor = a;
        _setSel(select(a, b, m.lineAt));
    }
    setState(() => _ver++);
    return true;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch) return _touch.move(e);
    _dragTo(e.localPosition, e.pointer);
  }

  void _dragTo(Offset local, int pointer) {
    if (pointer != _dragPointer || _clicks != 1) return;
    _dragAt = local;
    _extendTo(_dragAt);
    // Past the top or bottom edge of the stage above the soft keyboard (zoomed: of the grid seen there): scroll a
    // row every 50 ms while the button is held (C1).
    var seen = Rect.fromLTWH(0, 0, _stage.width, _stage.height - widget.keyboard);
    if (_zoom?.zoomed == true) seen = seen.intersect(_zfit);
    _edgeTop = seen.top;
    _edgeBottom = seen.bottom;
    final out = _dragAt.dy < _edgeTop || _dragAt.dy > _edgeBottom;
    if (!out) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
    } else {
      _edgeTimer ??= Timer.periodic(_edgeEvery, (_) {
        if (!mounted) return;
        _scroll(_dragAt.dy < _edgeTop ? 1 : -1);
        _extendTo(_dragAt);
      });
    }
  }

  void _extendTo(Offset local) {
    final m = _model, a = _anchor, p = _cellAt(local);
    if (m == null || a == null || p == null) return;
    if (_sel == null && p.y == a.y && p.x == a.x) return;
    setState(() {
      _setSel(select(a, p, m.lineAt, block: _dragBlock));
      _ver++;
    });
  }

  void _onUp(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch) return _touch.up(e);
    _release(e.pointer);
  }

  void _release(int? pointer) {
    if (pointer == null || pointer != _dragPointer) return;
    _dragPointer = null;
    _edgeTimer?.cancel();
    _edgeTimer = null;
  }

  // ---- touch (the recognizer's sink) ----

  @override
  bool press(PointerDownEvent e) => _pressAt(e.localPosition, e.timeStamp, e.pointer);

  @override
  void drag(PointerMoveEvent e) => _dragTo(e.localPosition, e.pointer);

  @override
  void release(Offset at, PointerEvent e) => _release(e.pointer);

  /// Two fingers scroll the history as a trackpad does.
  @override
  void scroll(Offset centre, Offset delta) => _scroll(delta.dy / _zoomed.cellH);

  /// The terminal has no right click.
  @override
  void rightTap(Offset at) {}

  /// T7: a second finger takes the keys.
  @override
  void twoDown(Offset centre) => _focus.requestFocus();

  @override
  void pan(Offset delta) {
    if (_fit.isEmpty) return;
    _zoom?.panBy(delta, _fit, _stage, keyboard: widget.keyboard);
  }

  @override
  void zoom(double z, Offset focal) {
    if (_fit.isEmpty) return;
    // A pinch back to where it started lands on exactly 1 (not a hair above it): unzoomed again.
    _zoom?.zoomTo((z - 1).abs() < 1e-9 ? 1 : z, focal, _fit, _stage, keyboard: widget.keyboard);
  }

  /// Nothing to tell A: the zoom is B's alone.
  @override
  void settled() {}

  void _onHover(PointerHoverEvent e) {
    _hover = e.localPosition;
    _updateHand();
  }

  void _updateHand() {
    final h = _hover;
    final hand = h != null && _linkKey && _linkAt(_cellAt(h)) != null;
    if (hand != _hand) setState(() => _hand = hand);
  }

  bool _onKeys(KeyEvent e) {
    if (mounted) _updateHand();
    return false;
  }

  // ---- copy (C2, C3) ----

  void _copy() {
    final m = _model, s = _sel;
    if (m == null || s == null) return;
    Clipboard.setData(ClipboardData(text: selectionText(s, m.lineAt, m.wrappedAt)));
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(_copiedFor, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    // A mouse hold on the voice button owns the keyboard (its Esc and Tab end the hold): none of it is the pane's.
    if (widget.state.voiceMouseHold == widget.session.sid) return KeyEventResult.handled;
    if (!_gateOn) return _termKey(node, e);
    final code = macKeyCode(e.physicalKey);
    if (code == null) return _termKey(node, e);
    _syncHotkey();
    final input = switch (e) {
      KeyDownEvent() => VoiceGateInput.down(code, macFlags(HardwareKeyboard.instance)),
      KeyRepeatEvent() => VoiceGateInput.down(code, macFlags(HardwareKeyboard.instance), repeat: true),
      _ => VoiceGateInput.up(code),
    };
    final step = _gateFeed(input, event: e);
    return step.pass ? _termKey(node, e) : KeyEventResult.handled;
  }

  KeyEventResult _termKey(FocusNode node, KeyEvent e) {
    debugTermKeySeen?.call(e);
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    // A selection first: its copy, and Esc only clears it (C2, C3).
    final copyKeys = _mac
        ? k.isMetaPressed && !k.isControlPressed && !k.isAltPressed
        : k.isControlPressed && k.isShiftPressed && !k.isMetaPressed && !k.isAltPressed;
    if (e.logicalKey == LogicalKeyboardKey.keyC && copyKeys && _sel != null) {
      _copy();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && _sel != null) {
      setState(() {
        _setSel(null);
        _ver++;
      });
      return KeyEventResult.handled;
    }
    final input = termInputOf(e, mac: _mac, pressed: k.logicalKeysPressed);
    if (input case TermAction(action: TermShortcut.copy)) {
      _copy();
      return KeyEventResult.handled;
    }
    // An exited pane (T4) takes nothing: nothing is sent or kept, and the window's own keys
    // (Esc, Ctrl+[ / ], Ctrl+O, F11) are the window's again.
    if (!_canInput || widget.frozen) return KeyEventResult.ignored;
    final ctrl = widget.session.termCtrl;
    if (ctrl.value && input != null) {
      // The key row's sticky ⌃: a letter goes as `Ctrl-<letter>`, anything else as it is; the ⌃ is used up.
      ctrl.value = false;
      if (input case TermText(:final text) when RegExp(r'^[a-zA-Z]$').hasMatch(text)) {
        widget.port.sendKeys(widget.session.sid, ['Ctrl-${text.toUpperCase()}']);
        _sentInput();
        return KeyEventResult.handled;
      }
    }
    switch (input) {
      case null:
        // Not the terminal's (Ctrl+Enter, macOS's other ⌘ chords): the window has it.
        return KeyEventResult.ignored;
      case TermKeys(:final keys):
        widget.port.sendKeys(widget.session.sid, keys);
        _sentInput();
      case TermText(:final text):
        widget.port.type(widget.session.sid, text);
        _sentInput();
      case TermAction():
        _paste();
      case TermReserved():
        break; // rapp's (find, font size); not the terminal's either
    }
    // A key the live terminal would take is never the window's.
    return KeyEventResult.handled;
  }

  /// Input can go to the pane on the stage: it has not exited (T4). A dropped link (N4) the port itself drops.
  bool get _canInput {
    final w = widget.session.currentWindow;
    return w != null && widget.port.pane(widget.session.sid, w)?.dead != true;
  }

  Future<void> _paste() async {
    final r = await widget.state.termPaste(widget.session);
    if (!mounted) return;
    if (r.sent) _sentInput(); // one line straight in: input, as a key is (H3, K6)
    final why = r.note;
    if (why != null) setState(() => _showNote(why));
  }

  /// Input went out (a key, text, a one-line paste): back to the latest (H3); an ellipsis when no screen
  /// answers within 0.3 s of the first input still unanswered (K6), however much more follows it.
  void _sentInput() {
    final m = _model;
    if (m == null) return;
    if (m.offset > 0) m.toBottom();
    // Already waiting: the earlier screen and its clock still stand.
    if (_echoFrom != null) return;
    _echoFrom = m.screen;
    _echoTimer?.cancel();
    _echoTimer = Timer(_echoWait, () {
      if (!mounted || _echoFrom == null || _waiting) return;
      setState(() {
        _waiting = true;
        _ver++;
      });
    });
  }

  void _endWait() {
    _echoTimer?.cancel();
    _echoTimer = null;
    _echoFrom = null;
    if (_waiting) {
      _waiting = false;
      _ver++;
    }
  }

  // ---- build ----

  void _look(BuildContext context) {
    final t = RappTokens.of(context);
    final theme = widget.state.prefs.theme;
    _tokens = t;
    final key = (theme, t.text, t.bg, t.mono, t.monoFallback.join('\u0000'));
    if (key != _lookKey) {
      _lookKey = key;
      _palette = termPaletteFor(theme, t);
      _metrics = TermMetrics.measure(termTextStyle(t));
      _sized.clear();
      _ver++;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (dpr != _dpr) {
      _dpr = dpr;
      _ver++;
    }
  }

  /// The metrics at font [size], measured once per size.
  TermMetrics _measured(double size) {
    if (size == _metrics.style.fontSize) return _metrics;
    final hit = _sized[size];
    if (hit != null) return hit;
    // Only the last few sizes are worth keeping: a resize goes through a new one every frame.
    if (_sized.length >= 4) _sized.clear();
    return _sized[size] = TermMetrics.measure(_metrics.style.copyWith(fontSize: size));
  }

  /// The metrics at font [size] for a [cols]×[rows] pane on a [w]×[h] stage. Glyph widths do not grow
  /// exactly with the font, so a grid that comes out larger than the stage is measured once more, smaller.
  TermMetrics _metricsAt(double size, int cols, int rows, double w, double h) {
    final m = _measured(size);
    if (w <= 0 || h <= 0 || cols <= 0 || rows <= 0) return m;
    final gw = cols * m.cellW, gh = rows * m.cellH;
    if (gw <= w + 0.5 && gh <= h + 0.5) return m;
    return _measured(size * math.min(w / gw, h / gh));
  }

  @override
  Widget build(BuildContext context) {
    _look(context);
    final t = _tokens!;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth, h = c.maxHeight;
      final cw = _metrics.cellW, ch = _metrics.cellH;
      _queueView(math.max(2, (w / cw).floor()), math.max(2, (h / ch).floor()));
      final m = _model;
      final shown = m != null && m.screen.isNotEmpty;
      final gridW = shown ? m.cols * cw : 0.0, gridH = shown ? m.rows * ch : 0.0;
      // The pane keeps the device's rows and columns; it is laid out at the font size that fits it to the
      // stage, up as well as down, and drawn at that size rather than stretched.
      final k = gridScale(w: w, h: h, gridW: gridW, gridH: gridH, up: !widget.state.prefs.termFit);
      _drawn = shown ? _metricsAt(math.max(4.0, _metrics.style.fontSize! * k), m.cols, m.rows, w, h) : _metrics;
      // The zoom (B's alone, never in the view asked for): the grid drawn at a bigger font, panned and clipped.
      _stage = Size(w, h);
      _fit = shown ? Rect.fromLTWH(0, 0, m.cols * _drawn.cellW, m.rows * _drawn.cellH) : Rect.zero;
      final zoom = _zoom;
      _zfit = zoom == null || !shown ? _fit : zoom.zfit(_fit, _stage, keyboard: widget.keyboard);
      final z = shown ? zoom?.z ?? 1.0 : 1.0;
      // The same object while neither changes: the painter repaints on a new one.
      if (!identical(_zoomedFrom, _drawn) || _zoomedZ != z) {
        _zoomedFrom = _drawn;
        _zoomedZ = z;
        _zoomed = z == 1 ? _drawn : TermMetrics.scaled(_drawn, z);
      }

      if (m != null && _linksVer != _ver) {
        _linksVer = _ver;
        // Only the rows in view: the top one and m.rows more (the last one partly shown).
        final top = (-m.offset).floor();
        _links = shown ? linksIn(top, math.min(m.rows - 1, top + m.rows), m.lineAt, m.wrappedAt) : const [];
      }
      final s = _sel;
      if (!identical(s, _countedSel)) {
        _countedSel = s;
        _count = s == null || m == null ? 0 : selectedChars(selectionText(s, m.lineAt, m.wrappedAt));
      }

      Widget grid = CustomPaint(
        key: const Key('term-grid'),
        painter: m == null
            ? null
            : TermPainter(
                model: m,
                metrics: _zoomed,
                palette: _palette,
                cache: _cache,
                version: _ver,
                dpr: _dpr,
                selection: s,
                links: _links,
                focused: _focus.hasFocus,
                waiting: _waiting,
              ),
      );
      grid = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onUp,
        onPointerHover: _onHover,
        onPointerSignal: _onSignal,
        onPointerPanZoomStart: _onPanStart,
        onPointerPanZoomUpdate: _onPanUpdate,
        onPointerPanZoomEnd: _onPanEnd,
        child: MouseRegion(
          cursor: _hand ? SystemMouseCursors.click : SystemMouseCursors.text,
          onExit: (_) {
            _hover = null;
            _updateHand();
          },
          child: ClipRect(
            child: Stack(children: [
              Positioned(left: _zfit.left, top: _zfit.top, right: 0, bottom: 0, child: grid),
            ]),
          ),
        ),
      );

      final note = _note;
      return KeepFocus(child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: ColoredBox(
          color: _palette.bg,
          child: Stack(children: [
            Positioned.fill(child: grid),
            if (s != null)
              Positioned(
                left: 12,
                top: 10,
                child: _Pill(
                  key: const Key('term-copy'),
                  tokens: t,
                  text: _copied ? '已复制' : '选中了 $_count 个字 · 复制到本机',
                  onTap: _copy,
                ),
              ),
            if (m != null && m.offset > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 14,
                child: Center(
                  child: _Pill(
                    key: const Key('term-latest'),
                    tokens: t,
                    text: m.newOutput ? '有新输出 · 回到最新' : '正在看历史 · 回到最新',
                    onTap: m.toBottom,
                  ),
                ),
              ),
            if (note != null)
              Positioned(
                left: 12,
                bottom: 14,
                child: _Pill(key: const Key('term-note'), tokens: t, text: note),
              ),
          ]),
        ),
      ));
    });
  }
}

/// A small boxed label over the grid (prototype: bg fill, text-coloured border).
class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.tokens, required this.text, this.onTap});

  final RappTokens tokens;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final radius = BorderRadius.circular(t.r);
    return Material(
      color: t.bg,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: t.text)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(text, style: TextStyle(color: t.text)),
        ),
      ),
    );
  }
}
