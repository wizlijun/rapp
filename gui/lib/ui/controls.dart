import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';

enum _Kind { primary, secondary, accent }

/// Button per design language section 8. Built on Material buttons, with a
/// 0.97 press scale (80 ms) unless reduced motion is on.
class RappButton extends StatefulWidget {
  const RappButton.primary({
    super.key,
    required this.label,
    this.onPressed,
    this.semanticLabel,
  }) : _kind = _Kind.primary;
  const RappButton.secondary({
    super.key,
    required this.label,
    this.onPressed,
    this.semanticLabel,
  }) : _kind = _Kind.secondary;
  const RappButton.accent({
    super.key,
    required this.label,
    this.onPressed,
    this.semanticLabel,
  }) : _kind = _Kind.accent;

  final String label;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final _Kind _kind;

  @override
  State<RappButton> createState() => _RappButtonState();
}

class _RappButtonState extends State<RappButton> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(t.r),
    );
    const min = Size(48, 48);
    final child = Text(widget.label);
    final Widget button = switch (widget._kind) {
      _Kind.primary => FilledButton(
        onPressed: widget.onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: t.text,
          foregroundColor: t.bg,
          minimumSize: min,
          shape: shape,
        ),
        child: child,
      ),
      _Kind.accent => FilledButton(
        onPressed: widget.onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.accentInk,
          minimumSize: min,
          shape: shape,
        ),
        child: child,
      ),
      _Kind.secondary => OutlinedButton(
        onPressed: widget.onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: t.raise.first,
          foregroundColor: t.text,
          side: BorderSide(color: t.line),
          minimumSize: min,
          shape: shape,
        ),
        child: child,
      ),
    };
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && !reduced ? .97 : 1,
        duration: reduced ? Duration.zero : const Duration(milliseconds: 80),
        child: widget.semanticLabel == null
            ? button
            : Semantics(
                label: widget.semanticLabel,
                excludeSemantics: true,
                button: true,
                enabled: widget.onPressed != null,
                onTap: widget.onPressed,
                child: button,
              ),
      ),
    );
  }
}

/// Irreversible action: a muted weak button; first tap arms it (accent style,
/// [confirmLabel]); a second tap within [reset] calls [onConfirmed].
class ConfirmButton extends StatefulWidget {
  const ConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.confirmLabel = '再点一次确认',
    this.reset = const Duration(seconds: 3),
  });
  final String label;
  final String confirmLabel;
  final VoidCallback? onConfirmed;
  final Duration reset;

  @override
  State<ConfirmButton> createState() => _ConfirmButtonState();
}

class _ConfirmButtonState extends State<ConfirmButton> {
  bool _armed = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tap() {
    if (_armed) {
      _timer?.cancel();
      setState(() => _armed = false);
      widget.onConfirmed?.call();
    } else {
      setState(() => _armed = true);
      _timer = Timer(widget.reset, () {
        if (mounted) setState(() => _armed = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onConfirmed != null;
    if (_armed) {
      return RappButton.accent(
        label: widget.confirmLabel,
        onPressed: enabled ? _tap : null,
      );
    }
    final t = RappTokens.of(context);
    return TextButton(
      onPressed: enabled ? _tap : null,
      style: TextButton.styleFrom(
        foregroundColor: t.muted,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.r)),
      ),
      child: Text(widget.label),
    );
  }
}
