// The composer bar: text, pasted blocks and files typed on B, sent to A through the runner.
// [按键] [附件] [editor + blocks] [复制] [发送] [收起]; the draft is the session's (R18).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'composer_model.dart';
import 'remote_session.dart';
import 'session_port.dart';

/// macOS modifier bits, as the runner's `key` takes them.
const commandBit = 1048576;
const optionBit = 524288;

/// The keys row: label, key code, and the modifier bit for the sticky ones.
const composerKeys = <(String, int, int?)>[
  ('Esc', 53, null),
  ('Tab', 48, null),
  ('⌘', 0, commandBit),
  ('⌥', 0, optionBit),
  ('←', 123, null),
  ('→', 124, null),
  ('↓', 125, null),
  ('↑', 126, null),
  ('删除', 51, null),
  ('回车', 36, null),
];

class ComposerBar extends StatefulWidget {
  const ComposerBar({super.key, required this.state, required this.session, required this.port});

  /// For `blurPicture`: keys typed here stay with rapp.
  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  @override
  State<ComposerBar> createState() => _ComposerBarState();
}

class _ComposerBarState extends State<ComposerBar> {
  final _field = FocusNode(debugLabel: 'composer');
  bool _keys = false;
  int _sticky = 0;

  ComposerModel get _m => widget.session.composer;
  Object get _sid => widget.session.sid;

  @override
  void initState() {
    super.initState();
    _field.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _field.removeListener(_focusChanged);
    _field.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (_field.hasFocus) widget.state.blurPicture();
  }

  /// Enter sends, Shift+Enter is a newline, Esc clears then closes, ⌘V asks the runner; while
  /// the input method is composing, Enter and Esc are its own.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final hw = HardwareKeyboard.instance;
    final composing = _m.controller.value.composing;
    final imeBusy = composing.isValid && !composing.isCollapsed;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (imeBusy) return KeyEventResult.ignored;
      if (hw.isShiftPressed) {
        _m.insertText('\n');
      } else if (e is KeyDownEvent) {
        _send();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (imeBusy) return KeyEventResult.ignored;
      _m.esc();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyV && hw.isMetaPressed && !hw.isAltPressed && !hw.isControlPressed) {
      if (e is KeyDownEvent) _paste();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final pieces = _m.pieces();
    if (_m.send() == SendOutcome.sent) widget.port.composerSend(_sid, pieces);
  }

  // The model outlives the bar while the session lives; it ignores results after its end.
  Future<void> _paste() async => _m.apply(await widget.port.composerPaste(_sid));

  Future<void> _attach() async => _m.apply(await widget.port.composerAttach(_sid));

  void _copy() {
    widget.port.key(_sid, 8, commandBit); // ⌘C on A
    _m.copyPressed();
  }

  void _key(int code) {
    widget.port.key(_sid, code, _sticky);
    setState(() => _sticky = 0);
  }

  Widget _keyButton((String, int, int?) k) {
    final (label, code, bit) = k;
    if (bit == null) return RappButton.secondary(label: label, onPressed: () => _key(code));
    final on = _sticky & bit != 0;
    void toggle() => setState(() => _sticky ^= bit);
    return on
        ? RappButton.primary(key: ValueKey('sticky-$label'), label: label, onPressed: toggle)
        : RappButton.secondary(key: ValueKey('sticky-$label'), label: label, onPressed: toggle);
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
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(widthFactor: 1, child: Text(b.label, style: TextStyle(color: t.text))),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // A press anywhere on the bar takes key focus from the picture (R24).
    return Listener(
      onPointerDown: (_) => widget.state.blurPicture(),
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.session, _m]),
        builder: (context, _) {
          final t = RappTokens.of(context);
          const gap = SizedBox(width: 8);
          final status = _m.status, transfer = widget.session.transferStatus;
          return Container(
            key: const Key('composer-bar'),
            decoration: t.panelBox(),
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_keys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [for (final k in composerKeys) _keyButton(k)]),
                  ),
                if (_m.blocks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [for (final b in _m.blocks) _chip(b, t)]),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    RappButton.secondary(label: '按键', onPressed: () => setState(() => _keys = !_keys)),
                    gap,
                    RappButton.secondary(label: '附件', onPressed: _attach),
                    gap,
                    Expanded(
                      child: Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onKeyEvent: _onKey,
                        child: TextField(
                          key: const Key('composer-field'),
                          controller: _m.controller,
                          focusNode: _field,
                          autofocus: true,
                          minLines: 1,
                          maxLines: 6,
                          keyboardType: TextInputType.multiline,
                          style: TextStyle(color: t.text),
                          decoration: const InputDecoration(
                            hintText: '发给 A 的文字（Enter 发送，Shift+Enter 换行）',
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                    gap,
                    RappButton.secondary(label: '复制', onPressed: _copy),
                    gap,
                    RappButton.primary(label: '发送', onPressed: _m.sending ? null : _send),
                    gap,
                    RappButton.secondary(label: '收起', onPressed: () => _m.open = false),
                  ],
                ),
                if (status != null || transfer != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        if (status != null) Expanded(child: Text(status, style: TextStyle(color: t.muted))),
                        if (status == null) const Spacer(),
                        if (transfer != null) ...[
                          gap,
                          Text(transfer, style: TextStyle(color: t.muted)),
                          gap,
                          RappButton.secondary(
                              label: '取消', onPressed: () => widget.port.cancelTransfer(_sid)),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The stage's composer layer: the 「输入」 button at the bottom right while closed (with the
/// upload strip, if any), the bar along the bottom while open. Both float over the picture and
/// never change the stage's size (R12).
List<Widget> composerLayer({required MainState state, required RemoteSession session, required SessionPort port}) {
  final both = Listenable.merge([session, session.composer]);
  return [
    Positioned(
      left: 8,
      right: 8,
      bottom: 8,
      child: ListenableBuilder(
        listenable: session.composer,
        builder: (context, _) => session.composer.open
            ? ComposerBar(state: state, session: session, port: port)
            : const SizedBox.shrink(),
      ),
    ),
    Positioned(
      right: 12,
      bottom: 12,
      child: ListenableBuilder(
        listenable: both,
        builder: (context, _) {
          if (session.composer.open) return const SizedBox.shrink();
          final t = RappTokens.of(context);
          final transfer = session.transferStatus;
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
