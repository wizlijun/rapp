// The writing panel (spec §3, W1–W16): a 720-wide box at the bottom of the stage, one line to
// start, growing upward to half the stage. From the top: the outgoing items, the hint line,
// the box with [editor] [＋] [发送]. The editor owns the text; the model copies it out
// at send, session switch, 1 s idle and collapse (spec §5). The draft is the session's (R18).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../term/term_key_row.dart';
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
import 'native_editor.dart';
import 'panel_place.dart';
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

/// How far the picture moves up while the writing panel is open (one line).
const pictureLift = 64.0;

/// One line of the editor (W2), the hit area of 「＋」 and 发送 (W13).
const _line = 48.0;

/// The box's border, top plus bottom.
const _border = 2.0;

/// ＋ and 发送's margin to the box (they are 40 square): one line is 40 + 2 × 8 = 56 inside the border.
const _edge = 8.0;

/// The editor's extra room above and below, so its one line (48) fills those 56.
const _pad = (40 + 2 * _edge - _line) / 2;

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
    );
    _attached = _m.attach(_ed);
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
      final sid = _s.sid;
      final ed = _ed;
      if (ed is NativeEditor) {
        ed.readyForInput.then((_) {
          if (mounted && _m.editorFocused && !_blocked) widget.port.composeReplay(sid);
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_blocked) widget.port.composeReplay(sid);
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
          final k = _k, line = _line * k, pad = _pad * k, edge = _edge * k;
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
              Container(
                key: const Key('composer-box'),
                decoration: seeThroughBox(t),
                constraints: BoxConstraints(maxHeight: inner + _border),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12, right: 8),
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
                    // ＋ and 发送: 40 square, [_edge] to the border on every side (one line), 4 between them.
                    Padding(
                      padding: EdgeInsets.all(edge),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ComposerPlus(
                            session: _s,
                            port: widget.port,
                            onAttach: _attach,
                            history: widget.state.history,
                            historyKey: widget.state.historyKeyOf(_s),
                            onPress: () => widget.state.holdForPanel(_s),
                            onReturnAfter: _s.appId.isEmpty
                                ? null
                                : (on) => widget.state.setAfterSend(_s, on ? AfterSend.pressReturn : AfterSend.none),
                            terminal: _terminal,
                            blocked: _blocked,
                            scale: k,
                            zoom: widget.state.composerZoom.value,
                            onZoom: widget.state.setComposerZoom,
                          ),
                          const SizedBox(width: 4),
                          RappButton.primary(
                            key: const Key('composer-send'),
                            label: '发送',
                            semanticLabel: '发送',
                            icon: Icons.arrow_upward,
                            size: 40 * k,
                            onPressed: _m.sending || _blocked ? null : _submit,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          }),
        ),
      ),
    );
  }
}

/// The stage's composer layer: the 「输入」 button at the bottom right while closed (with the
/// upload strip, if any), the writing panel at the bottom centre while open. Both float over
/// the picture and never change the stage's size (R12).
///
/// A terminal's [keyRow] (「按键排」) adds the six keys: on the panel's line at the stage's two bottom corners, with
/// 「输入」 just left of the right group; on a stage narrower than [keyRowWideAt] with the panel open, a line of its
/// own right above the panel.
///
/// With the soft keyboard up ([keyboard]: how far it reaches over the stage's bottom) all of it stands on the
/// keyboard's top edge instead, the panel 8 above it; the picture under it stays as it is.
List<Widget> composerLayer(
    {required MainState state,
    required RemoteSession session,
    required SessionPort port,
    bool keyRow = false,
    double keyboard = 0,
    ComposerEditor Function()? editor}) {
  final both = Listenable.merge([session, session.composer, state.composerZoom, state.stageSide]);
  final term = port is TermSessionPort ? port : null;
  final keys = keyRow && term != null;
  // The stage row's right inset: clear of the terminal key row when it shows.
  final rowRight = keys ? keyRowInset + keyRowGroupWidth + 8 : 12.0;
  bool open() => session.composer.open && session.composerAllowed;
  return [
    Positioned.fill(
      // The stage's origin for where the panel is (iOS's voice button stands above it).
      child: StageMark(
      child: ListenableBuilder(
        listenable: both,
        builder: (context, _) => open()
            ? LayoutBuilder(
                builder: (context, c) => term == null
                    // An app window: the panel floats where the app's place is (floating-composer spec).
                    ? FloatingComposer(
                        // Per session: a switch mid-drag drops that drag instead of saving it into the new app.
                        key: ValueKey(session.sid),
                        session: session,
                        scale: state.composerScale,
                        keyboard: keyboard,
                        place: panelPlaceOf(session),
                        onPlace: (p) => state.placeComposer(session, p),
                        child: ComposerPanel(
                          editor: editor,
                          key: ValueKey(session.sid),
                          state: state,
                          session: session,
                          port: port,
                          maxHeight: c.maxHeight / 2,
                        ),
                      )
                    : Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 8 + keyboard),
                    child: PanelPlace(
                      place: panelPlaceOf(session),
                      child: SizedBox(
                      width: panelWidth(c.maxWidth, state.composerScale),
                      // The key row comes and goes before the panel; the panel stays the same element.
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (keys && c.maxWidth < keyRowWideAt) TermKeyRow(port: term, sid: session.sid, ctrl: session.termCtrl, split: false, blocked: state.sendBlocked(session.sid)),
                          Flexible(
                            // Keyed by session: a switch is a new panel, and the old one's dispose
                            // copies its text into its own session's draft.
                            child: ComposerPanel(
                              editor: editor,
                              key: ValueKey(session.sid),
                              state: state,
                              session: session,
                              port: port,
                              maxHeight: c.maxHeight / 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
      ),
    ),
    // A terminal's key row on the panel's line; always in the list, so toggling it moves nothing else.
    if (term != null)
      Positioned.fill(
        child: ListenableBuilder(
          listenable: both,
          builder: (context, _) => keys
              ? LayoutBuilder(
                  builder: (context, c) => open() && c.maxWidth < keyRowWideAt
                      ? const SizedBox.shrink() // above the panel instead
                      : Container(
                          alignment: Alignment.bottomCenter,
                          padding: EdgeInsets.only(bottom: keyboard),
                          child: TermKeyRow(port: term, sid: session.sid, ctrl: session.termCtrl, split: true, blocked: state.sendBlocked(session.sid)),
                        ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    if (defaultTargetPlatform == TargetPlatform.iOS)
      // The stage buttons in one edge stack; the key row, if on, sits below it. Hold to talk draws over the stage.
      Positioned.fill(
        child: _IosStage(
          key: ValueKey(session.sid),
          state: state,
          session: session,
          port: port,
          // Portrait by the stage itself, not what the keyboard leaves of it.
          buttons: (hold) => LayoutBuilder(builder: (context, stage) => ListenableBuilder(
              listenable: Listenable.merge([both, session.zooms, ?hold]),
              builder: (context, _) {
                final transfer = session.transferStatus;
                final button = session.composerAllowed;
                final zoomed = session.currentZoomed && !session.composer.open;
                // An open panel takes the stack, all but 语音, which stands above the panel (user 2026-11-18:
                // 「输入版打开的时候不要隐藏这个语音输入」).
                if (session.composer.open && button) {
                  return hold == null ? const SizedBox.shrink() : _VoiceAbovePanel(state: state, session: session, hold: hold);
                }
                // A disallowed panel hides 输入, so the strip shows here.
                if (transfer == null && !button && !zoomed) return const SizedBox.shrink();
                final t = RappTokens.of(context);
                // The key row, if on, is under the stack: its own 88 clears it; on the keyboard the row comes
                // first.
                final row = keys ? keyRowBottom + keyRowKeySize.height + 8 : 0.0;
                return Padding(
                  padding: EdgeInsets.only(
                      bottom: keyboard > 0 ? keyboard + (keys ? row : stageButtonsEdge) : math.max(stageButtonsUp, row)),
                  child: Listener(
                  onPointerDown: (_) => state.holdForPanel(session),
                  child: StageButtons(
                    side: state.stageSide.value,
                    onSide: state.setStageSide,
                    // Shown exactly when 输入 is (an open panel returned above).
                    voice: hold != null && button ? voiceButton(hold) : null,
                    hidden: hold?.active ?? false,
                    upright: stage.maxHeight > stage.maxWidth,
                    input: button
                        ? RappButton.stage(
                            key: const Key('composer-open'),
                            label: '输入',
                            icon: Icons.keyboard_outlined,
                            size: stageButtonSize,
                            onPressed: () => session.composer.open = true,
                          )
                        : null,
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
                      if (hold?.hint != null) voiceHint(hold!),
                      if (transfer != null)
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
              },
            )),
        ),
      )
    else
    Positioned.fill(
      // The whole stage, so the Mac's voice bubble knows its width; the row sits in the corner as before.
      child: LayoutBuilder(
        builder: (context, stage) => Padding(
      padding: EdgeInsets.only(
        right: rowRight,
        bottom: (keys ? keyRowBottom : 12) + keyboard,
      ),
      child: Align(
      alignment: Alignment.bottomRight,
      child: ListenableBuilder(
        listenable: Listenable.merge([both, session.zooms]),
        builder: (context, _) {
          final transfer = session.transferStatus;
          final button = session.composerAllowed;
          final zoomed = session.currentZoomed && !session.composer.open;
          // An open panel hides it; a disallowed one is hidden, so the strip shows here.
          // 还原 shows even where 输入 is not allowed: else a zoomed such session could only be pinched back.
          if ((session.composer.open && button) || (transfer == null && !button && !zoomed)) return const SizedBox.shrink();
          final t = RappTokens.of(context);
          final items = <Widget>[
            if (transfer != null) ...[
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
            if (button)
              RappButton.secondary(
                key: const Key('composer-open'),
                label: '输入',
                semanticLabel: '输入',
                icon: Icons.keyboard_outlined,
                onPicture: true,
                seeThrough: true,
                onPressed: () => session.composer.open = true,
              ),
          ];
          // On the Mac the voice button is the row's right end; the rest fades while it holds, and it blurs the
          // picture itself (a refused press must not).
          if (button && (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux) && state.voice != null) {
            return DesktopVoice(
              key: ValueKey(session.sid),
              state: state,
              session: session,
              port: port,
              maxWidth: math.max(0.0, stage.maxWidth - rowRight),
              others: items,
            );
          }
          return Listener(
            onPointerDown: (_) => state.holdForPanel(session),
            child: Row(mainAxisSize: MainAxisSize.min, children: items),
          );
        },
      ),
      ),
        ),
      ),
    ),
    // 长语音先让 AI 整理's card, over everything; only the card takes taps (spec §5.3).
    Positioned.fill(
      child: _TidyLayer(state: state, session: session, both: both, keys: keys, keyboard: keyboard, rowRight: rowRight),
    ),
  ];
}

/// Where [VoiceTidyCard] stands. Desktop: right-aligned with the stage row, just above it; with the panel open,
/// above the panel and right-aligned with it (below it, or the row's corner, when there is no room). iOS: on the
/// stack's line above the stack; with the panel open, above 语音 (which stands above the panel).
class _TidyLayer extends StatelessWidget {
  const _TidyLayer(
      {required this.state,
      required this.session,
      required this.both,
      required this.keys,
      required this.keyboard,
      required this.rowRight});

  final MainState state;
  final RemoteSession session;
  final Listenable both;
  final bool keys;
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
    final base = (keys ? keyRowBottom : 12) + keyboard;
    final corner = Offset(stage.width - rowRight - card.width, stage.height - base - card.height);
    if (!_open) return corner.translate(0, -(control + 8));
    final p = panelPlaceOf(session).value;
    if (p == null) return corner;
    final x = p.right - card.width;
    if (p.top - 8 - card.height >= 8) return Offset(x, p.top - 8 - card.height);
    if (p.bottom + 8 + card.height <= stage.height - 8) return Offset(x, p.bottom + 8);
    return corner;
  }

  Offset _ios(Size stage, Size card) {
    final left = state.stageSide.value == StageSide.left;
    final x = left ? stageButtonsIn : stage.width - stageButtonsIn - card.width;
    final p = panelPlaceOf(session).value;
    double bottom;
    if (_open && p != null) {
      // 语音's bottom, as _VoiceAbovePanel puts it.
      final voice = math.max(0.0, math.min(stage.height - p.top + 8, stage.height - 8 - stageButtonSize));
      bottom = voice + stageButtonSize + 12;
    } else {
      final row = keys ? keyRowBottom + keyRowKeySize.height + 8 : 0.0;
      final base = keyboard > 0 ? keyboard + (keys ? row : stageButtonsEdge) : math.max(stageButtonsUp, row);
      final button = session.composerAllowed;
      final n = (button && state.voice != null ? 1 : 0) + (button ? 1 : 0) + (session.currentZoomed ? 1 : 0);
      final upright = stage.height > stage.width;
      final stack = n == 0 ? 0.0 : (upright ? stageButtonSize : n * stageButtonSize + (n - 1) * 12);
      bottom = base + stack + 12;
    }
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

/// The iOS stage's button stack plus hold to talk: owns the session's [VoiceHold] (none without
/// `state.voice`) and lays [VoiceOverlay] over the whole stage.
/// iOS's 语音 while the panel is open: the same stage button, on the stack's line ([stageButtonsIn] in from the
/// stack's side), 8 above the panel's top, or its key row's when that rides above it; the panel moves (the keyboard,
/// a drag), the button follows a frame behind. Never off the stage's top.
class _VoiceAbovePanel extends StatelessWidget {
  const _VoiceAbovePanel({required this.state, required this.session, required this.hold});

  final MainState state;
  final RemoteSession session;
  final VoiceHold hold;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Rect?>(
        valueListenable: panelPlaceOf(session),
        builder: (context, panel, _) {
          if (panel == null) return const SizedBox.shrink();
          final left = state.stageSide.value == StageSide.left;
          return LayoutBuilder(builder: (context, c) {
            final bottom = math.min(c.maxHeight - panel.top + 8, c.maxHeight - 8 - stageButtonSize);
            final hint = hold.active || hold.hint == null ? null : voiceHint(hold, maxWidth: c.maxWidth - 2 * stageButtonsIn - stageButtonSize - 12);
            return Stack(children: [
              Positioned(
                left: left ? stageButtonsIn : null,
                right: left ? null : stageButtonsIn,
                bottom: math.max(0, bottom),
                child: Listener(
                  onPointerDown: (_) => state.holdForPanel(session),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (left) voiceButton(hold),
                      if (hint != null) ...[if (left) const SizedBox(width: 12), hint, if (!left) const SizedBox(width: 12)],
                      if (!left) voiceButton(hold),
                    ],
                  ),
                ),
              ),
            ]);
          });
        },
      );
}

class _IosStage extends StatefulWidget {
  const _IosStage({super.key, required this.state, required this.session, required this.port, required this.buttons});

  final MainState state;
  final RemoteSession session;
  final SessionPort port;
  final Widget Function(VoiceHold? hold) buttons;

  @override
  State<_IosStage> createState() => _IosStageState();
}

class _IosStageState extends State<_IosStage> {
  VoiceHold? _hold;

  @override
  void initState() {
    super.initState();
    final voice = widget.state.voice;
    if (voice != null) {
      _hold = VoiceHold(
        voice: voice,
        // The widget, not the first one: a rebuild may bring a new port for the same session.
        send: (text) => sendVoice(state: widget.state, session: widget.session, port: widget.port, text: text),
        edit: (text) {
          final c = widget.session.composer;
          unawaited(c.keep(text));
          c.open = true;
        },
        composer: () => widget.session.composer,
        tidy: (text, pick, at) => widget.state.tidyOf(widget.session.sid).begin(text, pick, at: at),
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
