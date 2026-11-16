// The stage of a terminal session: draws the pane, asks for the size the stage can show (Z1), scrolls the
// history (H1, H2), selects and copies (C1–C5), opens links (L1) and, with focus, sends the keyboard (K1–K6).
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
    if (Platform.isMacOS) {
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

const _viewPause = Duration(milliseconds: 300);
const _multiClick = Duration(milliseconds: 500);
const _multiClickSlop = 4.0;
const _edgeEvery = Duration(milliseconds: 50);
const _noteFor = Duration(seconds: 3);
const _copiedFor = Duration(seconds: 1);

/// K6: how long a key or text may go without a new screen before the ellipsis shows.
const _echoWait = Duration(milliseconds: 300);

class TermStage extends StatefulWidget {
  const TermStage({super.key, required this.state, required this.session, required this.port, this.frozen = false});

  final MainState state;
  final RemoteSession session;
  final TermSessionPort port;

  /// A network drop: the picture stays for reading and copying, but no input goes out.
  final bool frozen;

  @override
  State<TermStage> createState() => _TermStageState();
}

typedef _View = ({int window, int cols, int rows});

class _TermStageState extends State<TermStage> with SingleTickerProviderStateMixin {
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
  late TermMetrics _metrics;
  double _dpr = 1;
  double _scale = 1;

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

  @override
  void initState() {
    super.initState();
    _fling = createTicker(_tick);
    widget.session.addListener(_onSession);
    _focus.addListener(_onFocus);
    HardwareKeyboard.instance.addHandler(_onKeys);
    _focusSeen = widget.state.termFocusTick;
    widget.state.addListener(_onState);
    _bind();
    _focusIfWanted();
  }

  @override
  void didUpdateWidget(TermStage old) {
    super.didUpdateWidget(old);
    if (!identical(old.state, widget.state)) {
      old.state.removeListener(_onState);
      widget.state.addListener(_onState);
      _focusSeen = widget.state.termFocusTick;
    }
    if (!identical(old.session, widget.session)) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _focusIfWanted();
    }
    if (!identical(old.session, widget.session) || !identical(old.port, widget.port)) {
      _sent = null;
      _bind();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    widget.state.removeListener(_onState);
    HardwareKeyboard.instance.removeHandler(_onKeys);
    _unbind();
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
  void _onSession() => setState(_bind);

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

  void _onFocus() => setState(() => _ver++);

  // ---- focus ----

  /// MainState asked for the keys to come here (`focusPicture`, a terminal opened or switched to).
  void _onState() {
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
    final v = (window: win, cols: _cols, rows: _rows);
    final sent = _sent;
    if (v == sent) {
      _viewTimer?.cancel();
      _pending = null;
      return;
    }
    // The first view of a pane goes at once; a new size waits until the stage stops changing.
    if (sent == null || sent.window != win) {
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
    widget.port.view(widget.session.sid, v.window, v.cols, v.rows);
  }

  // ---- scrolling (H1, H2) ----

  void _scroll(double rows) {
    final m = _model;
    if (m == null || m.alt || m.screen.isEmpty || rows == 0) return;
    m.scrollBy(rows);
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
      _stopFling();
      _scroll(-(ev as PointerScrollEvent).scrollDelta.dy / _metrics.cellH);
    });
  }

  void _onPanStart(PointerPanZoomStartEvent e) {
    _stopFling();
    _velocity = VelocityTracker.withKind(PointerDeviceKind.trackpad);
  }

  void _onPanUpdate(PointerPanZoomUpdateEvent e) {
    _velocity?.addPosition(e.timeStamp, e.pan);
    _scroll(e.panDelta.dy / _metrics.cellH);
  }

  void _onPanEnd(PointerPanZoomEndEvent e) {
    final m = _model, vt = _velocity;
    _velocity = null;
    if (m == null || vt == null || m.alt) return;
    final v = vt.getVelocity().pixelsPerSecond.dy / _metrics.cellH;
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
    final m = _model;
    if (m == null || m.screen.isEmpty) return null;
    final p = local / _scale;
    final top = (-m.offset).floor();
    final int y = (p.dy / _metrics.cellH - m.offset).floor().clamp(top, math.max(top, m.rows - 1));
    final int x = (p.dx / _metrics.cellW).floor().clamp(0, math.max(0, m.cols - 1));
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
    _focus.requestFocus();
    widget.state.blurPicture();
    _stopFling();
    if (e.buttons != kPrimaryButton) return;
    final m = _model;
    final p = _cellAt(e.localPosition);
    if (m == null || p == null) return;
    final link = _linkKey ? _linkAt(p) : null;
    if (link != null) {
      openUrl(link.url);
      return;
    }
    final last = _lastClick;
    final again = last != null &&
        e.timeStamp - last <= _multiClick &&
        (e.localPosition - _lastClickAt).distance <= _multiClickSlop;
    _clicks = again ? (_clicks == 3 ? 1 : _clicks + 1) : 1;
    _lastClick = e.timeStamp;
    _lastClickAt = e.localPosition;
    _dragPointer = e.pointer;
    _dragAt = e.localPosition;
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
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _dragPointer || _clicks != 1) return;
    _dragAt = e.localPosition;
    _extendTo(_dragAt);
    // Past the top or bottom edge: scroll a row every 50 ms while the button is held (C1).
    final h = context.size?.height ?? 0;
    final out = _dragAt.dy < 0 || _dragAt.dy > h;
    if (!out) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
    } else {
      _edgeTimer ??= Timer.periodic(_edgeEvery, (_) {
        if (!mounted) return;
        _scroll(_dragAt.dy < 0 ? 1 : -1);
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
    if (e.pointer != _dragPointer) return;
    _dragPointer = null;
    _edgeTimer?.cancel();
    _edgeTimer = null;
  }

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
      _ver++;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (dpr != _dpr) {
      _dpr = dpr;
      _ver++;
    }
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
      // The pane keeps the device's rows and columns; it is scaled to fit the stage, up as well as down.
      // A stage with no size, or a pane with none, keeps scale 1 (a scale of 0 would make every pointer position infinite).
      _scale = shown && w > 0 && h > 0 && gridW > 0 && gridH > 0 ? math.min(w / gridW, h / gridH) : 1.0;

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
                metrics: _metrics,
                palette: _palette,
                cache: _cache,
                version: _ver,
                dpr: _dpr,
                scale: _scale,
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
          child: grid,
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
    Widget box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: t.bg,
        border: Border.all(color: t.text),
        borderRadius: BorderRadius.circular(t.r),
      ),
      child: Text(text, style: TextStyle(color: t.text, fontSize: 13)),
    );
    final tap = onTap;
    if (tap != null) {
      box = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: tap, child: box),
      );
    }
    return box;
  }
}
