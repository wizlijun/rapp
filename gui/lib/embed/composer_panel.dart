// The writing panel (spec §3, W1–W16): a 720-wide box at the bottom of the stage, one line to
// start, growing upward to half the stage. From the top: the outgoing items, the hint line,
// the box with [＋] [editor] [发送]. The editor owns the text; the model copies it out
// at send, session switch, 1 s idle and collapse (spec §5). The draft is the session's (R18).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../term/term_session_port.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/prefs.dart' show StageSide;
import '../ui/tokens.dart';
import 'composer_editor.dart';
import 'composer_float.dart';
import 'composer_model.dart';
import 'app_profile.dart';
import 'composer_plus.dart';
import 'flutter_editor.dart';
import 'input_dock.dart';
import 'key_bar.dart';
import 'native_editor.dart';
import 'panel_place.dart';
import 'quick_toggle.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'stage_buttons.dart';
import 'voice_button.dart';
import 'voice_desktop.dart';
import 'voice_overlay.dart';
import 'voice_tidy_card.dart';

/// W1: 720 wide, or the stage less 16 when the stage is narrower than 736.
/// Zoomed ([scale] above 1) it is 720 × [scale], never wider than the stage less 16.
double panelWidth(double stageWidth, [double scale = 1]) =>
    stageWidth < 736 * scale ? math.max(0, stageWidth - 16) : 720 * scale;

/// One line of the editor (W2), the hit area of 「＋」 and 发送 (W13).
const _line = 48.0;

/// The box's border, top plus bottom.
const _border = 2.0;

/// ＋ and 发送's margin to the box (they are 40 square): one line is 40 + 2 × 8 = 56 inside the border.
const _edge = 8.0;

/// The editor's extra room above and below, so its one line (48) fills those 56.
const _pad = (40 + 2 * _edge - _line) / 2;

/// The text's least width in the box when the zoom makes the keys big (a phone at the top zoom step).
const _minText = 120.0;

/// The box row's width that does not scale: the border and the text's 8 on either side.
const _fixed = _border + 2 * 8;

/// The box row's key width per unit of zoom: ＋ and 发送 (40 each), and [_edge] on both sides of each.
const _keysPerScale = 2 * 40 + 4 * _edge;

/// The panel's boxes let the picture behind show through: the float fill 30% transparent.
const composerFillOpacity = 0.7;

/// The float box at [composerFillOpacity]: the composer's look, for anything else that sits on the picture.
BoxDecoration seeThroughBox(RappTokens t) {
  final d = t.floatBox();
  Color f(Color c) => c.withValues(alpha: c.a * composerFillOpacity);
  final g = d.gradient;
  return d.copyWith(
    color: d.color == null ? null : f(d.color!),
    gradient: g is LinearGradient
        ? LinearGradient(begin: g.begin, end: g.end, stops: g.stops, colors: [for (final c in g.colors) f(c)])
        : g,
  );
}

class ComposerPanel extends StatefulWidget {
  const ComposerPanel({
    super.key,
    required this.state,
    required this.session,
    required this.port,
    required this.maxHeight,
    this.editor,
  });

  /// For `holdForPanel`: keys typed here stay with rapp.
  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  /// The box's height limit (W3: half the stage); the editor scrolls inside it.
  final double maxHeight;

  /// Makes the editing area; NSTextView on macOS, [FlutterEditor] elsewhere.
  final ComposerEditor Function()? editor;

  @override
  State<ComposerPanel> createState() => _ComposerPanelState();
}

class _ComposerPanelState extends State<ComposerPanel> {
  late final ComposerEditor _ed;
  late final RemoteSession _s;
  late final ComposerModel _m;
  late final Future<void> _attached;
  late int _focusSeen, _releaseSeen;

  @override
  void initState() {
    super.initState();
    _s = widget.session;
    _m = _s.composer;
    _ed = widget.editor?.call() ??
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
            ? NativeEditor(
                onToggleFocus: widget.state.composerKey,
                onShortcut: (key) {
                  switch (key) {
                    case '[': widget.state.step(-1);
                    case ']': widget.state.step(1);
                    case 'o': widget.state.toggleOverview();
                    case 'd': widget.state.toggleDetach();
                    case 'zoom+': widget.state.zoomKey(ZoomKey.bigger);
                    case 'zoom-': widget.state.zoomKey(ZoomKey.smaller);
                    case 'zoom0': widget.state.zoomKey(ZoomKey.reset);
                  }
                },
              )
            : FlutterEditor());
    _ed.handlers = EditorHandlers(
      onChanged: _changed,
      onEnter: _submit,
      onEscape: _m.collapse, // W6: the text stays
      onPaste: _paste,
      onFocus: _focused,
      onArrow: _arrow,
      onZoom: widget.state.zoomKey,
      onLetter: (l) => defaultTargetPlatform == TargetPlatform.iOS && sendLatchedLetter(widget.state, _s, widget.port, l),
    );
    _attached = _m.attach(_ed);
    final saved = _m.selection;
    final ed = _ed;
    if (saved != null && ed is SelectionEditor) {
      // After the draft is in the editor (setText puts the caret at the end).
      _attached.then((_) {
        if (mounted) (ed as SelectionEditor).selection = saved;
      });
    }
    _focusSeen = _m.focusTick;
    _releaseSeen = _m.releaseTick;
    _m.addListener(_modelChanged);
    // Opened: the caret goes to the editor. Not `autofocus`, which yields to the main window's
    // already focused Focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _takeCaret();
      // Opened to paste (K4): the paste asked for before the panel was there.
      if (_m.takePaste()) _paste();
    });
  }

  @override
  void didUpdateWidget(ComposerPanel old) {
    super.didUpdateWidget(old);
    assert(identical(old.session, widget.session), 'key ComposerPanel by session');
  }

  @override
  void dispose() {
    _m.removeListener(_modelChanged);
    // Collapse, a session switch, the stage going away: the editor's text goes into the draft
    // first, then the editor is let go.
    final ed = _ed;
    if (ed is SelectionEditor) _m.selection = (ed as SelectionEditor).selection;
    _m.detach(ed).whenComplete(ed.dispose);
    super.dispose();
  }

  /// A terminal session's panel: what it sends is a paste into the pane.
  bool get _terminal => widget.port is TermSessionPort;

  /// Who the text is for: a terminal's current command (its session's name when the pane has none), else A's app.
  String get _to {
    final cmd = _terminal ? widget.state.termPaneOf(_s)?.command ?? '' : '';
    return cmd.isEmpty ? _s.appName : cmd;
  }

  void _changed() => _m.editorChanged();

  /// R2: ↑ and ↓ at the first or last line go through what was sent (the session's model keeps the
  /// round and the text being written, so a collapse or a session switch loses nothing).
  bool _arrow(bool up) => _m.arrow(up);

  void _focused(bool on) {
    if (mounted) widget.state.composerFocusChanged(_s, on);
  }

  void _modelChanged() {
    if (_m.focusTick != _focusSeen) {
      _focusSeen = _m.focusTick;
      _takeCaret();
    }
    if (_m.releaseTick != _releaseSeen) {
      _releaseSeen = _m.releaseTick;
      _ed.unfocus();
    }
    if (_m.takePaste()) _paste();
  }

  /// The most a held compose letter waits for the input method switch: the runner drops it after 1.5 s,
  /// and a leave still queued ahead of the switch can take up to ~900 ms.
  static const _imeWait = Duration(milliseconds: 300);

  /// The editor gets key focus, and the picture loses it (also when the editor already had
  /// Flutter's focus while the picture took the keys).
  Future<void> _takeCaret() async {
    await _attached;
    if (!mounted) return;
    _ed.focus();
    widget.state.holdForPanel(_s);
    if (_m.takeReplay()) {
      // The held compose letter goes back to the window only after the editor is the text input
      // client (focus attaches it in a microtask), so B's input method composes it: next frame.
      // And only after the switch to Chinese the caret's arrival asked for has ended (ImeIntent).
      final sid = _s.sid;
      final ed = _ed;
      final state = widget.state;
      if (ed is NativeEditor) {
        ed.readyForInput.then((_) async {
          await state.imeSettled.timeout(_imeWait, onTimeout: () {});
          if (mounted && _m.editorFocused && !_blocked) widget.port.composeReplay(sid);
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await state.imeSettled.timeout(_imeWait, onTimeout: () {});
          if (mounted && _m.editorFocused && !_blocked) widget.port.composeReplay(sid);
        });
        WidgetsBinding.instance.scheduleFrame();
      }
    }
  }

  /// A network drop froze the session: nothing goes to the remote, the draft stays (offline-freeze spec).
  bool get _blocked => widget.state.isDetaching(_s.sid) || widget.state.sendBlocked(_s.sid);

  // Text goes after A is set for it (English input, the marked box clicked); an empty send is
  // a Return for A's app. The session outlives the panel: a take that ends after the panel is
  // gone still sends.
  Future<void> _submit() async {
    if (_blocked) return;
    final port = widget.port;
    switch (await _m.submit()) {
      case SubmitPieces(:final pieces):
        if (_blocked) {
          _m.done(0, '连接已断开或正在移动，内容尚未发送');
          return;
        }
        _s.prepareInput();
        port.composerSend(_s.sid, pieces);
      case SubmitReturn():
        if (!_blocked) _s.pressReturn();
      case SubmitNothing():
        break;
    }
  }

  void _retry(Outgoing o) {
    if (_blocked) return;
    final pieces = _m.retry(o);
    if (pieces == null) return;
    _s.prepareInput();
    widget.port.composerSend(_s.sid, pieces);
  }

  void _putBack(Outgoing o) {
    _m.putBack(o);
    _takeCaret();
  }

  // The model ignores results that come after the session's end.
  Future<void> _paste() async {
    if (widget.state.isDetaching(_s.sid)) return;
    final port = widget.port;
    await _m.applyPending(port.composerPaste(_s.sid));
  }

  Future<void> _attach() async {
    if (widget.state.isDetaching(_s.sid)) return;
    final port = widget.port;
    await _m.applyPending(port.composerAttach(_s.sid));
  }

  /// The line above the box (W11): paste and attach notes, an upload with 取消, and A on an
  /// input method. Not there when none of them is.
  Widget? _hint(RappTokens t) {
    final status = _m.status, transfer = _s.transferStatus, src = _s.inputSource;
    final ime = src != null && !src.ascii;
    if (status == null && transfer == null && !ime) return null;
    const gap = SizedBox(width: 8);
    const cut = TextOverflow.ellipsis; // one line each, whatever the stage's width
    return Padding(
      key: const Key('composer-hint'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          // Both sides give way on a narrow stage; the notes and the IME line keep the larger share.
          Expanded(
            flex: 2,
            child: Row(
              children: [
                if (status != null)
                  Flexible(child: Text(status, maxLines: 1, overflow: cut, style: TextStyle(color: t.muted))),
                if (status != null && ime) gap,
                if (ime)
                  Flexible(
                    child: InkWell(
                      onTap: () => _s.selectInput(''),
                      borderRadius: BorderRadius.circular(t.r),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: controlHeightOf(context)),
                        child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        child: Text(
                          '远端在用输入法 ${src.name}，发送前会切到英文 · 点按现在就切',
                          maxLines: 1,
                          overflow: cut,
                          style: TextStyle(color: t.accent, fontWeight: FontWeight.w600),
                        ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (transfer != null) ...[
            gap,
            Flexible(child: Text(transfer, maxLines: 1, overflow: cut, style: TextStyle(color: t.muted))),
            gap,
            RappButton.secondary(label: '取消', onPicture: true, onPressed: () => widget.port.cancelTransfer(_s.sid)),
          ],
        ],
      ),
    );
  }

  /// One outgoing item: 「发送中」 or why it failed, the text's first line, and for a failed
  /// one 「重试」 and 「放回输入框」.
  Widget _item(Outgoing o, RappTokens t) {
    final failure = o.failure;
    final first = o.text.isNotEmpty ? o.text.split('\n').first : o.blocks.map((b) => b.label).join(' ');
    const gap = SizedBox(width: 8);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: seeThroughBox(t),
        constraints: BoxConstraints(minHeight: _line * _k + _border),
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      failure ?? '发送中',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: failure == null ? t.muted : t.accent),
                    ),
                  ),
                  gap,
                  Flexible(
                    child: Text(first, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.muted)),
                  ),
                ],
              ),
            ),
            if (failure != null) ...[
              gap,
              RappButton.secondary(label: '重试', onPressed: _m.sending || _m.taking || _blocked ? null : () => _retry(o)),
              const SizedBox(width: 4),
              RappButton.secondary(label: '放回输入框', onPressed: () => _putBack(o)),
            ],
          ],
        ),
      ),
    );
  }

  /// The zoom (⌘= / ⌘- / ⌘0): every size below is its default times this.
  double get _k => widget.state.composerScale;

  @override
  Widget build(BuildContext context) {
    // A press anywhere on the panel takes key focus from the picture (R24).
    return Listener(
      key: const Key('composer-panel'),
      onPointerDown: (_) => widget.state.holdForPanel(_s),
      child: ListenableBuilder(
        listenable: Listenable.merge([_s, _m, widget.state.history, widget.state.composerZoom]),
        builder: (context, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(_k)),
          child: Builder(builder: (context) {
          final t = RappTokens.of(context);
          final k = _k, line = _line * k, pad = _pad * k;
          final style = EditorStyle(
            text: TextStyle(
              fontSize: t.textSize * k, height: 22 / 15, fontFamily: t.font,
              fontFamilyFallback: t.fontFallback, color: t.text, shadows: const [],
            ),
            color: t.text,
            hintColor: t.muted,
            cursor: t.text,
          );
          // Inside the border; the editor never gets less than one line.
          final inner = math.max(line + 2 * pad, widget.maxHeight - _border);
          final inFlight = _m.inFlight;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The rows get what the hint line and the box leave, and scroll (opening at the
              // bottom): the box and 发送 always stay on stage.
              if (inFlight != null || _m.failed.isNotEmpty)
                Flexible(
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (inFlight != null) _item(inFlight, t),
                        for (final o in _m.failed) _item(o, t),
                      ],
                    ),
                  ),
                ),
              ?_hint(t), // W11
              LayoutBuilder(builder: (context, c) {
              // The keys zoom with the text, but give way on a narrow panel so the text keeps [_minText] wide
              // (never under their default 40); the text itself keeps the zoom.
              final kk = math.min(k, math.max(1.0, (c.maxWidth - _fixed - _minText) / _keysPerScale));
              final edge = _edge * kk;
              return Container(
                key: const Key('composer-box'),
                decoration: seeThroughBox(t),
                constraints: BoxConstraints(maxHeight: inner + _border),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // ＋ on the left, 发送 on the right: 40 square, [_edge] to the border on every side (one line),
                    // times the keys' zoom; both sit at the bottom as the text grows. The 快捷区 toggle is not here:
                    // it stays beside 收起 (bar-cmd addendum).
                    Padding(
                      padding: EdgeInsets.all(edge),
                      child: ComposerPlus(
                        state: widget.state,
                        session: _s,
                        port: widget.port,
                        onAttach: _attach,
                        history: widget.state.history,
                        historyKey: widget.state.historyKeyOf(_s),
                        onAddPhrase: widget.state.addPhrase,
                        onPress: () => widget.state.holdForPanel(_s),
                        onReturnAfter: _s.appId.isEmpty
                            ? null
                            : (on) => widget.state.setAfterSend(_s, on ? AfterSend.pressReturn : AfterSend.none),
                        terminal: _terminal,
                        blocked: _blocked,
                        scale: kk,
                        zoom: widget.state.composerZoom.value,
                        onZoom: widget.state.setComposerZoom,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Never under one line; [_pad] above and below it, so one line is as tall as ＋
                            // and 发送 with their margins. Blocks sit in the text as chips (composer_model.dart).
                            Flexible(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: pad),
                                // Selecting and scrolling stay the text's: a floating panel moves from here
                                // only after a touch held still (composer_float.dart).
                                child: MetaData(
                                  metaData: composerTextArea,
                                  behavior: HitTestBehavior.translucent,
                                  child: LayoutBuilder(
                                    // The font size is already zoomed: the editor takes no text scale on top.
                                    builder: (context, c) => MediaQuery.withNoTextScaling(
                                      child: _ed.view(
                                        context,
                                        style: style,
                                        hint: _m.canRecall ? '写给 $_to · ↑ 上一条' : '写给 $_to',
                                        maxHeight: math.max(line, c.maxHeight),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 发送 alone on the right, away from the keys on the left, so it is not hit by mistake.
                    Padding(
                      padding: EdgeInsets.all(edge),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RappButton.primary(
                            key: const Key('composer-send'),
                            label: '发送',
                            semanticLabel: '发送',
                            icon: Icons.arrow_upward,
                            size: 40 * kk,
                            onPressed: _m.sending || _blocked ? null : _submit,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
              }),
            ],
          );
          }),
        ),
      ),
    );
  }
}

/// The stage's composer layer, on every platform: the session's [InputDock] — the writing panel and the 快捷区 in one
/// block floating at the session's place, and the stage's controls (iOS's button stack; elsewhere the corner row at the
/// bottom right, with the upload strip, if any). All of it floats over the picture and never changes the stage's size
/// or moves it (R12, input-dock spec).
///
/// With the soft keyboard up ([keyboard]: how far it reaches over the stage's bottom) the block stands 8 above the
/// keyboard's top edge instead; the picture under it stays as it is.
List<Widget> composerLayer(
    {required MainState state,
    required RemoteSession session,
    required SessionPort port,
    double keyboard = 0,
    ComposerEditor Function()? editor}) {
  final both = Listenable.merge([session, session.composer, state.composerZoom, state.stageSide]);
  const rowRight = 12.0;
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  return [
    Positioned.fill(
      child: _InputStage(
        key: ValueKey(session.sid),
        state: state,
        session: session,
        port: port,
        buttons: (hold) => InputDock(
          key: ValueKey(session.sid),
          state: state,
          session: session,
          port: port,
          keyboard: keyboard,
          // The state too: the 快捷区 toggle, ⋯ and the 常用语条 change the 快捷区.
          listenable: Listenable.merge([both, state, session.zooms, ?hold]),
          voice: hold != null,
          text: (context, maxHeight) => ComposerPanel(
            editor: editor,
            // Keyed by session: a switch is a new panel, and the old one's dispose copies its text into its own
            // session's draft.
            key: ValueKey(session.sid),
            state: state,
            session: session,
            port: port,
            maxHeight: maxHeight,
          ),
          stack: (context, bottom, stage, upright) => ios
              ? _iosStack(context, state, session, port, hold, bottom, stage, upright)
              : _cornerRow(context, state, session, port, keyboard, rowRight, stage),
        ),
      ),
    ),
    // 长语音先让 AI 整理's card, over everything; only the card takes taps (spec §5.3).
    Positioned.fill(
      child: _TidyLayer(
          state: state,
          session: session,
          both: Listenable.merge([both, state]),
          keyboard: keyboard,
          rowRight: rowRight),
    ),
  ];
}

/// Off iOS, the stage's corner row: 输入 (收起 while the text area is open) at the bottom right, [rowRight] in and 12
/// over the [keyboard], with 还原 and the upload strip beside it; 语音 its right end on macOS and Linux. It stays where
/// it is whatever the block does.
Widget _cornerRow(BuildContext context, MainState state, RemoteSession session, SessionPort port, double keyboard,
    double rowRight, Size stage) {
  final transfer = session.transferStatus;
  final button = session.composerAllowed;
  final open = session.composer.open && button;
  final zoomed = session.currentZoomed && !session.composer.open;
  // A disallowed panel hides 输入, so the strip shows here.
  // 还原 shows even where 输入 is not allowed: else a zoomed such session could only be pinched back.
  if (transfer == null && !button && !zoomed) return const SizedBox.shrink();
  final t = RappTokens.of(context);
  final items = <Widget>[
    // Open, the panel's hint line carries the upload with its own 取消.
    if (transfer != null && !open) ...[
      DecoratedBox(
        decoration: t.floatBox(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(transfer, style: TextStyle(color: t.muted)),
        ),
      ),
      const SizedBox(width: 8),
      RappButton.secondary(label: '取消', onPicture: true, onPressed: () => port.cancelTransfer(session.sid)),
      const SizedBox(width: 8),
    ],
    if (zoomed) ...[
      RappButton.secondary(
        key: const Key('zoom-reset'),
        label: '还原',
        semanticLabel: '还原',
        icon: Icons.zoom_in_map,
        onPicture: true,
        seeThrough: true,
        onPressed: session.restoreCurrent,
      ),
      if (button) const SizedBox(width: 8),
    ],
    // The 快捷区 toggle stands left of 输入 (收起 while open), the text area open or not (bar-cmd addendum).
    if (button) ...[
      QuickToggle(state: state, session: session, look: QuickToggleLook.corner),
      const SizedBox(width: 8),
    ],
    // 输入 and 收起 are one button, always in its corner: it folds the text area only.
    if (button)
      RappButton.secondary(
        key: const Key('composer-open'),
        label: open ? '收起' : '输入',
        semanticLabel: open ? '收起' : '输入',
        icon: open ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined,
        onPicture: true,
        seeThrough: true,
        active: open,
        onPressed: open ? session.composer.collapse : () => session.composer.open = true,
      ),
  ];
  // On the Mac the voice button is the row's right end; the rest fades while it holds, and it blurs the
  // picture itself (a refused press must not).
  final row = button &&
          (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux) &&
          state.voice != null
      ? DesktopVoice(
          key: ValueKey(session.sid),
          state: state,
          session: session,
          port: port,
          maxWidth: math.max(0.0, stage.width - rowRight),
          others: items,
        )
      : Listener(
          onPointerDown: (_) => state.holdForPanel(session),
          child: Row(mainAxisSize: MainAxisSize.min, children: items),
        );
  return Padding(
    padding: EdgeInsets.only(right: rowRight, bottom: 12 + keyboard),
    child: Align(alignment: Alignment.bottomRight, child: row),
  );
}

/// iOS's stage stack, its bottom [bottom] up off the [stage]'s bottom: 语音, 输入 (收起 while the panel is open: one
/// element either way, so its icon turns over) and the 快捷区 toggle; closed, 还原 and the upload strip too. [upright] as
/// [stackUprightOf] has it: a portrait stage, or a column with no room above the block.
Widget _iosStack(BuildContext context, MainState state, RemoteSession session, SessionPort port, VoiceHold? hold,
    double bottom, Size stage, bool upright) {
  final transfer = session.transferStatus;
  final button = session.composerAllowed;
  final open = session.composer.open && button;
  final zoomed = session.currentZoomed && !session.composer.open;
  // A disallowed panel hides 输入, so the strip shows here.
  if (transfer == null && !button && !zoomed) return const SizedBox.shrink();
  final t = RappTokens.of(context);
  // An open panel keeps 语音 (user 2026-11-18: 「输入版打开的时候不要隐藏这个语音输入」), the 快捷区 toggle and 收起.
  final hint = hold == null || hold.hint == null || (open && hold.active)
      ? null
      : voiceHint(hold, maxWidth: open ? stage.width - 2 * stageButtonsIn - stageButtonSize - 12 : null);
  return Padding(
    padding: EdgeInsets.only(bottom: math.max(0, bottom)),
    child: Listener(
      onPointerDown: (_) => state.holdForPanel(session),
      child: StageButtons(
        side: state.stageSide.value,
        onSide: state.setStageSide,
        voice: hold != null && button ? voiceButton(hold) : null,
        hidden: hold?.active ?? false,
        upright: upright,
        input: button ? _openToggle(session) : null,
        // The 快捷区 toggle stands above 输入 (收起 while open), the text area open or not (bar-cmd addendum).
        quick: button ? QuickToggle(state: state, session: session, look: QuickToggleLook.stage) : null,
        restore: zoomed
            ? RappButton.stage(
                key: const Key('zoom-reset'),
                label: '还原',
                icon: Icons.zoom_in_map,
                size: stageButtonSize,
                onPressed: session.restoreCurrent,
              )
            : null,
        beside: [
          ?hint,
          if (transfer != null && !open)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: t.floatBox(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(transfer, style: TextStyle(color: t.muted)),
                  ),
                ),
                const SizedBox(width: 8),
                RappButton.secondary(label: '取消', onPicture: true, onPressed: () => port.cancelTransfer(session.sid)),
              ],
            ),
        ],
      ),
    ),
  );
}

/// Where [VoiceTidyCard] stands. Desktop: above the input block (text area, quick area or both) and right-aligned
/// with it, 8 up; below it when there is no room above; in the corner above the row when there is no block (both
/// folded). iOS: 12 above the stack, which stands above the block.
class _TidyLayer extends StatelessWidget {
  const _TidyLayer(
      {required this.state,
      required this.session,
      required this.both,
      required this.keyboard,
      required this.rowRight});

  final MainState state;
  final RemoteSession session;
  final Listenable both;
  final double keyboard;
  final double rowRight;

  @override
  Widget build(BuildContext context) {
    final tidy = state.tidyOf(session.sid);
    final control = controlHeightOf(context);
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    return ListenableBuilder(
      listenable: Listenable.merge([both, session.zooms, panelPlaceOf(session), tidy, state.stageSide]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, c) {
          // Where the voice bubble stood at the release: the card takes its place, its width and its top
          // (user 2026-11-20); with the panel open, or none, its own place.
          // Into the layer's own coordinates here, in the builder: the layout below may not read other boxes.
          final at = _open ? null : tidy.at;
          final b = context.findRenderObject() as RenderBox?;
          final local = at != null && b != null && b.attached ? b.globalToLocal(at.topLeft) : null;
          return CustomSingleChildLayout(
            delegate: _TidyPlace(
              width: math.max(0.0, math.min(local != null ? at!.width : 360.0, c.maxWidth - 24)),
              place: (stage, card) => local ?? (ios ? _ios(stage, card) : _desktop(stage, card, control)),
            ),
            child: VoiceTidyCard(
              key: ValueKey(session.sid),
              tidy: tidy,
              right: !ios || state.stageSide.value != StageSide.left,
              tail: ios,
            ),
          );
        },
      ),
    );
  }

  bool get _open => session.composer.open && session.composerAllowed;

  Offset _desktop(Size stage, Size card, double control) {
    final base = 12 + keyboard;
    final corner = Offset(stage.width - rowRight - card.width, stage.height - base - card.height - (control + 8));
    final p = panelPlaceOf(session).value;
    if (p == null || p.height == 0) return corner;
    final x = p.right - card.width;
    if (p.top - 8 - card.height >= 8) return Offset(x, p.top - 8 - card.height);
    if (p.bottom + 8 + card.height <= stage.height - 8) return Offset(x, p.bottom + 8);
    return corner;
  }

  Offset _ios(Size stage, Size card) {
    final left = state.stageSide.value == StageSide.left;
    final x = left ? stageButtonsIn : stage.width - stageButtonsIn - card.width;
    // The stack's top, as InputDock puts it.
    final voice = state.voice != null;
    final buttons = stackButtonCount(session, voice: voice);
    final upright = stackUprightOf(
        stage: stage,
        block: panelPlaceOf(session).value,
        keyboard: keyboard,
        columnHeight: stackHeightOf(buttons: buttons, upright: false));
    final h = stackHeightOf(buttons: buttons, upright: upright);
    final bottom =
        stackBottomOf(stage: stage, block: panelPlaceOf(session).value, keyboard: keyboard, stackHeight: h) + h + 12;
    return Offset(x, stage.height - bottom - card.height);
  }
}

class _TidyPlace extends SingleChildLayoutDelegate {
  _TidyPlace({required this.width, required this.place});

  final double width;
  final Offset Function(Size stage, Size card) place;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: width, maxHeight: constraints.maxHeight);

  // Never off the stage: 12 in from each side, 8 from the top.
  @override
  Offset getPositionForChild(Size size, Size child) {
    final o = place(size, child);
    return Offset(o.dx.clamp(12.0, math.max(12.0, size.width - 12 - child.width)),
        o.dy.clamp(8.0, math.max(8.0, size.height - child.height)));
  }

  @override
  bool shouldRelayout(_TidyPlace old) => true;
}

/// 输入 and 收起 are one key: the keyboard to open the panel, the hiding keyboard to put it away.
Widget _openToggle(RemoteSession session) {
  final open = session.composer.open;
  return RappButton.stage(
    key: const Key('composer-open'),
    label: open ? '收起' : '输入',
    icon: open ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined,
    size: stageButtonSize,
    active: open,
    onPressed: open ? session.composer.collapse : () => session.composer.open = true,
  );
}

/// The stage's input dock plus, on iOS, hold to talk: owns the session's [VoiceHold] there (none without
/// `state.voice`, nor off iOS, where the corner row has its own) and lays [VoiceOverlay] over the whole stage.
class _InputStage extends StatefulWidget {
  const _InputStage({super.key, required this.state, required this.session, required this.port, required this.buttons});

  final MainState state;
  final RemoteSession session;
  final SessionPort port;
  final Widget Function(VoiceHold? hold) buttons;

  @override
  State<_InputStage> createState() => _InputStageState();
}

class _InputStageState extends State<_InputStage> {
  VoiceHold? _hold;

  @override
  void initState() {
    super.initState();
    final voice = widget.state.voice;
    if (voice != null && defaultTargetPlatform == TargetPlatform.iOS) {
      _hold = VoiceHold(
        voice: voice,
        // The widget, not the first one: a rebuild may bring a new port for the same session.
        send: (text, heard) => sendVoice(
            state: widget.state, session: widget.session, port: widget.port, text: text, voice: VoiceOrigin(heard: heard)),
        edit: (text, heard) {
          final c = widget.session.composer;
          unawaited(c.keep(text));
          // Words said into a password field are not learned, even once the focus has left it (D7).
          c.pendingHeard = widget.session.secureFocus ? null : heard;
          c.open = true;
        },
        composer: () => widget.session.composer,
        tidy: (text, pick, at, heard) =>
            widget.state.tidyOf(widget.session.sid).begin(text, pick, at: at, heard: heard.heard),
        fix: (t) => widget.state.voiceFix(widget.session.sid, t),
        log: widget.state.voiceLog,
        wouldTidy: (text) => widget.state.tidyOf(widget.session.sid).would(text),
        onPress: () => widget.state.tidyIfAny(widget.session.sid)?.interrupt(),
        prefetch: (t) => t == null
            ? widget.state.tidyIfAny(widget.session.sid)?.prefetch(null)
            : widget.state.tidyOf(widget.session.sid).prefetch(t),
      );
    }
  }

  @override
  void dispose() {
    _hold?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hold = _hold;
    final voice = widget.state.voice;
    return Stack(
      children: [
        Positioned.fill(child: widget.buttons(hold)),
        if (hold != null && voice != null) Positioned.fill(child: VoiceOverlay(hold: hold, voice: voice)),
      ],
    );
  }
}
