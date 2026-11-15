// The writing panel (spec §3, W1–W16): a 720-wide box at the bottom of the stage, one line to
// start, growing upward to half the stage. From the top: the outgoing items, the hint line,
// the box with [blocks / editor] [＋] [发送]. The editor owns the text; the model copies it out
// at send, session switch, 1 s idle and collapse (spec §5). The draft is the session's (R18).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../history/input_history.dart';
import '../term/term_key_row.dart';
import '../term/term_session_port.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'composer_editor.dart';
import 'composer_model.dart';
import 'composer_plus.dart';
import 'flutter_editor.dart';
import 'remote_session.dart';
import 'session_port.dart';

/// W1: 720 wide, or the stage less 16 when the stage is narrower than 736.
double panelWidth(double stageWidth) => stageWidth < 736 ? math.max(0, stageWidth - 16) : 720;

/// How far the picture moves up while the writing panel is open (one line).
const pictureLift = 64.0;

/// One line of the editor (W2), the hit area of 「＋」 and 发送 (W13).
const _line = 48.0;

/// The box's border, top plus bottom.
const _border = 2.0;

class ComposerPanel extends StatefulWidget {
  const ComposerPanel({
    super.key,
    required this.state,
    required this.session,
    required this.port,
    required this.maxHeight,
    this.editor,
  });

  /// For `blurPicture`: keys typed here stay with rapp.
  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  /// The box's height limit (W3: half the stage); the editor scrolls inside it.
  final double maxHeight;

  /// Makes the editing area; [FlutterEditor] by default.
  final ComposerEditor Function()? editor;

  @override
  State<ComposerPanel> createState() => _ComposerPanelState();
}

class _ComposerPanelState extends State<ComposerPanel> {
  late final ComposerEditor _ed;
  late final RemoteSession _s;
  late final ComposerModel _m;
  late int _focusSeen, _releaseSeen;

  @override
  void initState() {
    super.initState();
    _s = widget.session;
    _m = _s.composer;
    _ed = (widget.editor ?? FlutterEditor.new)();
    _ed.handlers = EditorHandlers(
      onChanged: _changed,
      onEnter: _submit,
      onEscape: _m.collapse, // W6: the text stays
      onPaste: _paste,
      onFocus: _focused,
      onArrow: _arrow,
    );
    _m.attach(_ed);
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

  /// R2: which of [_recall] the editor shows untouched; null while not browsing.
  int? _browsing;

  /// Bumped at each text put in: a read started before it says nothing of the text now.
  int _shown = 0;

  List<InputEntry> get _recall => widget.state.recallOf(_s);

  /// A terminal session's panel: what it sends is a paste into the pane.
  bool get _terminal => widget.port is TermSessionPort;

  /// Who the text is for: a terminal's current command (its session's name when the pane has none), else A's app.
  String get _to {
    final cmd = _terminal ? widget.state.termPaneOf(_s)?.command ?? '' : '';
    return cmd.isEmpty ? _s.appName : cmd;
  }

  void _changed() {
    _m.editorChanged();
    if (_browsing == null) return;
    // The echo of what was put in, or a change by hand: that ends browsing.
    final list = _recall, i = _browsing!, at = _shown;
    final want = i < list.length ? list[i].text : null;
    _ed.read().then((t) {
      if (_browsing != null && _shown == at && t != want) _browsing = null;
    }, onError: (Object _) {});
  }

  /// ↑ on an empty editor puts in the last record; while it shows one untouched, ↑ goes to the
  /// one before (staying at the oldest), ↓ back, and ↓ from the last one empties the editor.
  bool _arrow(bool up) {
    final list = _recall;
    final i = _browsing;
    if (i == null) {
      if (!up || list.isEmpty || !_ed.isEmpty) return false;
      _show(0, list);
    } else if (list.isEmpty || (!up && i == 0)) {
      _browsing = null;
      _shown++;
      _ed.setText('');
    } else {
      _show(math.min(up ? i + 1 : i - 1, list.length - 1), list);
    }
    return true;
  }

  void _show(int i, List<InputEntry> list) {
    if (_browsing == i) return; // the oldest: up stays
    _browsing = i;
    _shown++;
    _ed.setText(list[i].text);
  }

  void _focused(bool on) {
    _m.editorFocused = on;
    if (on) widget.state.blurPicture();
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
  void _takeCaret() {
    _ed.focus();
    widget.state.blurPicture();
  }

  // Text goes after A is set for it (English input, the marked box clicked); an empty send is
  // a Return for A's app. The session outlives the panel: a take that ends after the panel is
  // gone still sends.
  Future<void> _submit() async {
    final port = widget.port;
    switch (await _m.submit()) {
      case SubmitPieces(:final pieces):
        _s.prepareInput();
        port.composerSend(_s.sid, pieces);
      case SubmitReturn():
        _s.pressReturn();
      case SubmitNothing():
        break;
    }
  }

  void _retry(Outgoing o) {
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
    final port = widget.port;
    _m.apply(await port.composerPaste(_s.sid));
  }

  Future<void> _attach() async {
    final port = widget.port;
    _m.apply(await port.composerAttach(_s.sid));
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
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '远端在用输入法 ${src.name}，发送前会切到英文 · 点按现在就切',
                          maxLines: 1,
                          overflow: cut,
                          style: TextStyle(color: t.accent, fontWeight: FontWeight.w600),
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
            RappButton.secondary(label: '取消', onPressed: () => widget.port.cancelTransfer(_s.sid)),
          ],
        ],
      ),
    );
  }

  Widget _chip(BlockChip b, RappTokens t) => Semantics(
        button: true,
        label: '移除 ${b.label}',
        excludeSemantics: true,
        child: InkWell(
          onTap: () => _m.removeBlock(b.n),
          borderRadius: BorderRadius.circular(t.r),
          child: CustomPaint(
            foregroundPainter: DashedOutline(t.line, t.r),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _line),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(widthFactor: 1, child: Text(b.label, style: TextStyle(color: t.text))),
              ),
            ),
          ),
        ),
      );

  /// One outgoing item: 「发送中」 or why it failed, the text's first line, and for a failed
  /// one 「重试」 and 「放回输入框」.
  Widget _item(Outgoing o, RappTokens t) {
    final failure = o.failure;
    final first = o.text.isNotEmpty ? o.text.split('\n').first : o.blocks.map((b) => b.label).join(' ');
    const gap = SizedBox(width: 8);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: t.panelBox(),
        constraints: const BoxConstraints(minHeight: _line + _border),
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
              RappButton.secondary(label: '重试', onPressed: _m.sending || _m.taking ? null : () => _retry(o)),
              const SizedBox(width: 4),
              RappButton.secondary(label: '放回输入框', onPressed: () => _putBack(o)),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A press anywhere on the panel takes key focus from the picture (R24).
    return Listener(
      key: const Key('composer-panel'),
      onPointerDown: (_) => widget.state.blurPicture(),
      child: ListenableBuilder(
        listenable: Listenable.merge([_s, _m, widget.state.history]),
        builder: (context, _) {
          final t = RappTokens.of(context);
          final style = EditorStyle(
            text: TextStyle(fontSize: 15, height: 22 / 15, fontFamily: t.font, color: t.text, shadows: const []),
            color: t.text,
            hintColor: t.muted,
            cursor: t.text,
          );
          // Inside the border; the editor never gets less than one line.
          final inner = math.max(_line, widget.maxHeight - _border);
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
                decoration: t.panelBox(),
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
                            if (_m.blocks.isNotEmpty)
                              ConstrainedBox(
                                constraints: BoxConstraints(maxHeight: inner - _line),
                                child: SingleChildScrollView(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [for (final b in _m.blocks) _chip(b, t)],
                                    ),
                                  ),
                                ),
                              ),
                            // What is left after the blocks row, never under one line.
                            Flexible(
                              child: LayoutBuilder(
                                builder: (context, c) => _ed.view(
                                  context,
                                  style: style,
                                  hint: _recall.isEmpty ? '写给 $_to' : '写给 $_to · ↑ 上一条',
                                  maxHeight: math.max(_line, c.maxHeight),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ComposerPlus(
                      session: _s,
                      port: widget.port,
                      onAttach: _attach,
                      history: widget.state.history,
                      historyKey: widget.state.historyKeyOf(_s),
                      onPress: widget.state.blurPicture,
                      terminal: _terminal,
                    ),
                    const SizedBox(width: 4),
                    RappButton.primary(
                      key: const Key('composer-send'),
                      label: '发送',
                      semanticLabel: '发送',
                      icon: Icons.arrow_upward,
                      onPressed: _m.sending ? null : _submit,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
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
List<Widget> composerLayer(
    {required MainState state, required RemoteSession session, required SessionPort port, bool keyRow = false}) {
  final both = Listenable.merge([session, session.composer]);
  final term = port is TermSessionPort ? port : null;
  final keys = keyRow && term != null;
  bool open() => session.composer.open && session.composerAllowed;
  return [
    Positioned.fill(
      child: ListenableBuilder(
        listenable: both,
        builder: (context, _) => open()
            ? LayoutBuilder(
                builder: (context, c) => Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: panelWidth(c.maxWidth),
                      // The key row comes and goes before the panel; the panel stays the same element.
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (keys && c.maxWidth < keyRowWideAt) TermKeyRow(port: term, sid: session.sid, split: false),
                          Flexible(
                            // Keyed by session: a switch is a new panel, and the old one's dispose
                            // copies its text into its own session's draft.
                            child: ComposerPanel(
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
              )
            : const SizedBox.shrink(),
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
                      : Align(
                          alignment: Alignment.bottomCenter,
                          child: TermKeyRow(port: term, sid: session.sid, split: true),
                        ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    Positioned(
      right: keys ? keyRowInset + keyRowGroupWidth + 8 : 12,
      bottom: keys ? keyRowBottom : 12,
      child: ListenableBuilder(
        listenable: both,
        builder: (context, _) {
          final transfer = session.transferStatus;
          final button = session.composerAllowed;
          // An open panel hides it; a disallowed one is hidden, so the strip shows here.
          if ((session.composer.open && button) || (transfer == null && !button)) return const SizedBox.shrink();
          final t = RappTokens.of(context);
          return Listener(
            onPointerDown: (_) => state.blurPicture(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (transfer != null) ...[
                  DecoratedBox(
                    decoration: t.panelBox(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(transfer, style: TextStyle(color: t.muted)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  RappButton.secondary(label: '取消', onPressed: () => port.cancelTransfer(session.sid)),
                  const SizedBox(width: 8),
                ],
                if (button)
                  RappButton.secondary(
                    key: const Key('composer-open'),
                    label: '输入',
                    onPressed: () => session.composer.open = true,
                  ),
              ],
            ),
          );
        },
      ),
    ),
  ];
}
