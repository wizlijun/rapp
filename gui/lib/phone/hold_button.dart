/// The phone home's reply button (V1c Task 9): fires on release, not on press. Tokens only.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/tokens.dart';
import 'widgets.dart';

const holdConfirmLabel = '再点一次确认';

/// Press shows the pressed look; sending happens on release over the button. Sliding off before release cancels,
/// a different [armKey] under the finger voids the press (C6), and a [risky] reply needs a second release within
/// [confirmFor] (C10).
class PhoneHoldButton extends StatefulWidget {
  const PhoneHoldButton({
    super.key,
    required this.label,
    required this.armKey,
    required this.onSend,
    this.primary = false,
    this.risky = false,
    this.leading,
    this.confirmFor = const Duration(seconds: 3),
  });
  final String label;

  /// What the card under the finger is. A change while pressed voids the press and any pending confirm.
  final Object armKey;
  final VoidCallback? onSend;
  final bool primary;
  final bool risky;
  final Widget? leading;
  final Duration confirmFor;

  @override
  State<PhoneHoldButton> createState() => _PhoneHoldButtonState();
}

class _PhoneHoldButtonState extends State<PhoneHoldButton> {
  bool _pressed = false;
  bool _armed = false;
  Timer? _timer;

  @override
  void didUpdateWidget(PhoneHoldButton old) {
    super.didUpdateWidget(old);
    if (old.armKey != widget.armKey) {
      _pressed = false;
      _disarm();
    }
    if (widget.onSend == null || !widget.risky) {
      _pressed = _pressed && widget.onSend != null;
      _disarm();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
    _armed = false;
  }

  bool _inside(Offset local) {
    final size = context.size;
    return size != null && (Offset.zero & size).contains(local);
  }

  void _fire() {
    final send = widget.onSend;
    if (send == null) return;
    if (widget.risky && !_armed) {
      setState(() => _armed = true);
      _timer?.cancel();
      _timer = Timer(widget.confirmFor, () {
        if (mounted) setState(_disarm);
      });
      return;
    }
    if (_armed) setState(_disarm);
    send();
  }

  void _down(PointerDownEvent e) {
    if (!mounted) return;
    if (widget.onSend == null) return;
    setState(() => _pressed = true);
  }

  void _move(PointerMoveEvent e) {
    if (!mounted) return;
    final inside = _inside(e.localPosition);
    if (inside != _pressed && widget.onSend != null) setState(() => _pressed = inside);
    // Once off the button a pending confirm is cancelled only on release (see _up).
  }

  void _up(PointerUpEvent e) {
    if (!mounted) return;
    if (!_pressed) {
      // Released off the button, or voided: cancel, including a pending confirm.
      if (_armed) setState(_disarm);
      return;
    }
    setState(() => _pressed = false);
    if (_inside(e.localPosition)) {
      _fire();
    } else if (_armed) {
      setState(_disarm);
    }
  }

  void _cancel(PointerCancelEvent e) {
    if (!mounted) return;
    if (_pressed || _armed) {
      setState(() {
        _pressed = false;
        _disarm();
      });
    }
  }

  void _semanticTap() => _fire();

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    final enabled = widget.onSend != null;
    final text = _armed ? holdConfirmLabel : widget.label;
    final Color bg;
    final Color fg;
    Color border;
    if (_pressed) {
      bg = t.accent;
      fg = t.accentInk;
      border = t.accent;
    } else if (_armed) {
      bg = t.tint;
      fg = t.accent;
      border = t.accent;
    } else if (widget.primary) {
      bg = t.text;
      fg = t.bg;
      border = t.text;
    } else {
      bg = t.raise.first;
      fg = t.text;
      border = t.line;
    }
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: text,
        excludeSemantics: true,
        onTap: enabled ? _semanticTap : null,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _cancel,
          child: Container(
            key: const Key('hold-box'),
            constraints: const BoxConstraints(minHeight: phonePrimaryTap),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(t.r), border: Border.all(color: border)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 8)],
                Flexible(
                  child: Text(text, textAlign: TextAlign.center, softWrap: true, style: style?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
