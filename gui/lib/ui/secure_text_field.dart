import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// macOS: while a password field has focus, secure event input is on and an ASCII keyboard layout
/// is selected (Flutter's `obscureText` leaves the input method on, so pinyin candidates would pop
/// up over a password). Linux uses the toolkit's per-context password purpose and suppresses
/// the candidate bridge while focused. Calls pair: one `end` per `begin`.
abstract final class SecureInput {
  static const channel = MethodChannel('rapp/secure-input');

  static void begin() => _call('begin');
  static void end() => _call('end');

  static void _call(String method) {
    channel.invokeMethod<void>(method).catchError((Object _) {}, test: (e) => e is MissingPluginException);
  }
}

/// A password TextField that keeps the input method out while it has focus (see [SecureInput]).
class SecureTextField extends StatefulWidget {
  const SecureTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.autofocus = false,
    this.enabled,
    this.decoration = const InputDecoration(),
    this.onSubmitted,
    this.onChanged,
    this.onTap,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool? enabled;
  final InputDecoration decoration;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  /// After the tap has placed the caret.
  final GestureTapCallback? onTap;

  @override
  State<SecureTextField> createState() => _SecureTextFieldState();
}

class _SecureTextFieldState extends State<SecureTextField> {
  FocusNode? _own;
  /// True between our `begin` and its `end`.
  bool _engaged = false;

  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  @override
  void didUpdateWidget(SecureTextField old) {
    super.didUpdateWidget(old);
    final before = old.focusNode ?? _own;
    if (before != _node) {
      before?.removeListener(_sync);
      _node.addListener(_sync);
      _sync();
    }
  }

  void _sync() {
    final focused = _node.hasFocus;
    if (focused == _engaged) return;
    _engaged = focused;
    focused ? SecureInput.begin() : SecureInput.end();
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    // A dialog closed with the field still focused never sees a blur.
    if (_engaged) SecureInput.end();
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    focusNode: _node,
    autofocus: widget.autofocus,
    enabled: widget.enabled,
    obscureText: true,
    // Flutter's Linux engine maps this type to GTK_INPUT_PURPOSE_PASSWORD;
    // obscureText alone only masks glyphs and does not set the IM context purpose.
    keyboardType: TextInputType.visiblePassword,
    enableSuggestions: false,
    autocorrect: false,
    enableIMEPersonalizedLearning: false,
    decoration: widget.decoration,
    onSubmitted: widget.onSubmitted,
    onChanged: widget.onChanged,
    onTap: widget.onTap,
  );
}
