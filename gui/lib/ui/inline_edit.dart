// Text that turns into a one-line field on tap (S5 K17): Enter or losing
// focus commits once, Esc cancels.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

class InlineEdit extends StatefulWidget {
  const InlineEdit({
    super.key,
    required this.text,
    required this.onCommit,
    this.placeholder = '',
    this.style,
    this.semanticLabel,
  });
  final String text;
  final ValueChanged<String> onCommit;
  final String placeholder;
  final TextStyle? style;
  final String? semanticLabel;

  @override
  State<InlineEdit> createState() => _InlineEditState();
}

class _InlineEditState extends State<InlineEdit> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'InlineEdit');
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_editing && !_focus.hasFocus) _finish(commit: true);
  }

  void _start() {
    _controller.value = TextEditingValue(
      text: widget.text,
      selection: TextSelection(baseOffset: 0, extentOffset: widget.text.length),
    );
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _focus.requestFocus();
    });
  }

  void _finish({required bool commit}) {
    if (!_editing) return;
    final value = _controller.text;
    setState(() => _editing = false);
    if (commit) widget.onCommit(value);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = widget.style ?? TextStyle(color: t.text);
    if (_editing) {
      return Focus(
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
            _finish(commit: false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              style: style,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 8,
                ),
              ),
              onSubmitted: (_) => _finish(commit: true),
            ),
          ),
        ),
      );
    }
    final empty = widget.text.isEmpty;
    final shown = empty ? widget.placeholder : widget.text;
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? shown,
      excludeSemantics: true,
      onTap: _start,
      child: InkWell(
        onTap: _start,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              shown,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: empty ? style.copyWith(color: t.muted) : style,
            ),
          ),
        ),
      ),
    );
  }
}
