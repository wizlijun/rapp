import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';

enum _Kind { primary, secondary, accent, round }

/// Button per design language section 8. Built on Material buttons, with a
/// 0.97 press scale (80 ms) unless reduced motion is on.
class RappButton extends StatefulWidget {
  const RappButton.primary({
    super.key,
    required this.label,
    this.onPressed,
    this.semanticLabel,
    this.focusNode,
    this.icon,
    this.size = 48,
  }) : _kind = _Kind.primary,
       onPicture = false,
       oneLine = false;
  const RappButton.secondary({
    super.key,
    required this.label,
    this.onPressed,
    this.semanticLabel,
    this.focusNode,
    this.icon,
    this.onPicture = false,
    this.size = 48,
    this.oneLine = false,
  }) : _kind = _Kind.secondary;
  const RappButton.accent({
    super.key,
    required this.label,
    this.onPressed,
    this.semanticLabel,
    this.focusNode,
    this.icon,
  }) : _kind = _Kind.accent,
       onPicture = false,
       oneLine = false,
       size = 48;

  /// A flat circle of [size] on the remote picture, icon only: the stage's edge buttons (iOS). No shadow.
  const RappButton.round({
    super.key,
    required this.label,
    required IconData this.icon,
    required this.size,
    this.onPressed,
  }) : _kind = _Kind.round,
       semanticLabel = null,
       focusNode = null,
       onPicture = true,
       oneLine = false;

  final String label;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final FocusNode? focusNode;

  /// Shown instead of [label]: a square 48×48 button (give it a [semanticLabel]).
  final IconData? icon;

  /// The square side for an [icon] button; below 48 only where the layout asks for it (the
  /// writing panel's ＋ and 发送, 40 with an even 4 around them).
  final double size;

  /// Drawn straight over the remote picture: the fill is the raise colour laid on the opaque float
  /// surface, so a see-through theme (AVATAR) never lets the picture show through the button.
  final bool onPicture;

  /// The label stays on one line and ends in … when the button is made narrower than it.
  final bool oneLine;
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
    final icon = widget.icon;
    final min = icon == null ? const Size(48, 48) : Size.square(widget.size);
    // A smaller square is the whole button: no padded tap target around it.
    final tap = widget.size < 48 ? MaterialTapTargetSize.shrinkWrap : null;
    final child = icon == null
        ? (widget.oneLine ? Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis) : Text(widget.label))
        : Icon(icon);
    final pad = icon == null ? null : EdgeInsets.zero;
    final Widget button = switch (widget._kind) {
      _Kind.primary => FilledButton(
        onPressed: widget.onPressed,
        focusNode: widget.focusNode,
        style: FilledButton.styleFrom(
          backgroundColor: t.text,
          foregroundColor: t.bg,
          minimumSize: min,
          tapTargetSize: tap,
          padding: pad,
          shape: shape,
        ),
        child: child,
      ),
      _Kind.accent => FilledButton(
        onPressed: widget.onPressed,
        focusNode: widget.focusNode,
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.accentInk,
          minimumSize: min,
          tapTargetSize: tap,
          padding: pad,
          shape: shape,
        ),
        child: child,
      ),
      _Kind.round => OutlinedButton(
        onPressed: widget.onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: Color.alphaBlend(t.raise.first, t.float.first),
          foregroundColor: t.text,
          elevation: 0,
          shadowColor: Colors.transparent,
          side: BorderSide(color: t.line),
          fixedSize: Size.square(widget.size),
          minimumSize: Size.square(widget.size),
          padding: EdgeInsets.zero,
          shape: CircleBorder(side: BorderSide(color: t.line)),
        ),
        child: child,
      ),
      _Kind.secondary => OutlinedButton(
        onPressed: widget.onPressed,
        focusNode: widget.focusNode,
        style: OutlinedButton.styleFrom(
          backgroundColor: widget.onPicture ? Color.alphaBlend(t.raise.first, t.float.first) : t.raise.first,
          foregroundColor: t.text,
          side: BorderSide(color: t.line),
          minimumSize: min,
          tapTargetSize: tap,
          padding: pad,
          shape: shape,
        ),
        child: child,
      ),
    };
    // An icon button has no text: its name for assistive tech is the semantic label or the label.
    final name = widget.semanticLabel ?? (icon == null ? null : widget.label);
    final reduced =
        MediaQuery.disableAnimationsOf(context) || widget.onPressed == null;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && !reduced ? .97 : 1,
        duration: reduced ? Duration.zero : const Duration(milliseconds: 80),
        child: name == null
            ? button
            : Semantics(
                label: name,
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
  final FocusNode _focus = FocusNode(debugLabel: 'ConfirmButton');

  @override
  void dispose() {
    _timer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _tap() {
    // The weak and armed buttons are different widgets; carry keyboard focus
    // across the swap so Enter/Space can confirm.
    final hadFocus = _focus.hasFocus;
    if (hadFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
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
        focusNode: _focus,
      );
    }
    final t = RappTokens.of(context);
    return TextButton(
      onPressed: enabled ? _tap : null,
      focusNode: _focus,
      style: TextButton.styleFrom(
        foregroundColor: t.muted,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.r)),
      ),
      child: Text(widget.label),
    );
  }
}

/// A rounded 1 px dashed outline: the add-device card and the composer's blocks.
class DashedOutline extends CustomPainter {
  DashedOutline(this.color, this.radius);
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(.5),
        Radius.circular(radius),
      ));
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 8) {
        canvas.drawPath(m.extractPath(d, (d + 4).clamp(0, m.length)), p);
      }
    }
  }

  @override
  bool shouldRepaint(DashedOutline o) => o.color != color || o.radius != radius;
}
