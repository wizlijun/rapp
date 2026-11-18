import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Where a menu opened at global point [p] goes, inside [context]'s overlay.
RelativeRect menuAt(BuildContext context, Offset p) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return RelativeRect.fromLTRB(p.dx, p.dy, overlay.size.width - p.dx, overlay.size.height - p.dy);
}

enum _Kind { primary, secondary, accent, quiet }

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
  const RappButton.quiet({
    super.key,
    required this.label,
    this.onPressed,
    this.semanticLabel,
    this.focusNode,
    this.icon,
  }) : _kind = _Kind.quiet,
       onPicture = false,
       oneLine = false,
       size = 48;

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
      _Kind.quiet => TextButton(
        onPressed: widget.onPressed,
        focusNode: widget.focusNode,
        style: TextButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: t.muted,
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
    return RappButton.quiet(
      label: widget.label,
      onPressed: enabled ? _tap : null,
      focusNode: _focus,
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

TextStyle _rowLabel(RappTokens t, TextStyle? style, bool muted) =>
    (style ?? const TextStyle()).copyWith(color: muted ? t.muted : (style?.color ?? t.text));

/// A label with a switch at the right end; the whole row toggles it. [switchKey] is the inner
/// [Switch]'s key and [key] the row's. Without [onChanged] the row is inert and muted.
///
/// [key] goes on the inner [InkWell], not on the widget itself, so a finder by that key (a tap target in
/// tests, a lookup in code) matches exactly one widget instead of the row and its tap target both.
class RappSwitchRow extends StatelessWidget {
  // ignore: use_key_in_widget_constructors
  const RappSwitchRow({
    Key? key,
    this.switchKey,
    required this.label,
    this.note,
    required this.value,
    this.onChanged,
    this.dim = false,
    this.style,
  }) : _rowKey = key;

  final Key? _rowKey;
  final Key? switchKey;
  final String label;

  /// A second line under the label, in muted.
  final String? note;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// The label is drawn in muted (an inherited value).
  final bool dim;

  /// Overrides the label style.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final on = onChanged;
    final labelStyle = _rowLabel(t, style, dim || on == null);
    return MergeSemantics(
      child: InkWell(
        key: _rowKey,
        borderRadius: BorderRadius.circular(t.r),
        onTap: on == null ? null : () => on(!value),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: controlHeightOf(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: labelStyle),
                    if (note != null) Text(note!, style: labelStyle.copyWith(color: t.muted)),
                  ],
                ),
              ),
              // Material's switch is 52×32; at 0.73 it sits in the row like the dropdown arrows.
              SizedBox(
                width: 38,
                height: 24,
                child: FittedBox(
                  child: Switch(
                    key: switchKey,
                    value: value,
                    onChanged: on,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A checkbox followed by its label; the whole row toggles it.
class RappCheckRow extends StatelessWidget {
  const RappCheckRow({super.key, required this.label, required this.value, this.onChanged, this.style});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final on = onChanged;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(t.r),
        onTap: on == null ? null : () => on(!value),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: controlHeightOf(context)),
          child: Row(children: [
            Checkbox(
              value: value,
              onChanged: on == null ? null : (v) => on(v ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 4),
            Expanded(child: Text(label, style: _rowLabel(t, style, on == null))),
          ]),
        ),
      ),
    );
  }
}

/// One of a set of mutually exclusive choices: a radio icon and a label.
class RappChoice extends StatelessWidget {
  const RappChoice({super.key, required this.label, required this.selected, this.onTap, this.dim = false});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// The label is drawn in muted (an inherited value).
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(t.r),
        onTap: onTap,
        child: SizedBox(
          height: controlHeightOf(context),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 18, color: selected ? t.accent : t.muted),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: dim ? t.muted : t.text)),
          ]),
        ),
      ),
    );
  }
}

/// One row of a [RappDropdown] or [showRappMenu] menu. [lead] goes before the label (a lamp, an icon),
/// [trailing] after it (a window's close ×). A disabled row is a caption: it is not picked and is muted.
class RappMenuItem<T> {
  const RappMenuItem({
    required T this.value,
    required this.label,
    this.key,
    this.lead,
    this.trailing,
    this.enabled = true,
    this.onSecondaryTapUp,
  }) : divider = false;

  /// A caption row: text only, never picked, muted.
  const RappMenuItem.caption({required this.label})
    : value = null,
      key = null,
      lead = null,
      trailing = null,
      enabled = false,
      onSecondaryTapUp = null,
      divider = false;

  /// A thin rule between groups of rows.
  const RappMenuItem.divider()
    : value = null,
      label = '',
      key = null,
      lead = null,
      trailing = null,
      enabled = false,
      onSecondaryTapUp = null,
      divider = true;

  final T? value;
  final String label;
  final Key? key;
  final Widget? lead;
  final Widget? trailing;
  final bool enabled;

  /// A right-click on the row; [row] is a context inside it, for popping the menu with another result.
  final void Function(BuildContext row, TapUpDetails details)? onSecondaryTapUp;
  final bool divider;
}

/// Opens a menu of [items] at [position]. With a non-null [current] it is a pick-one menu: every row has
/// an 18-wide tick column and the row whose value is [current] holds the tick. Without it, an action menu.
/// Rows are at least a control high; the look comes from the theme's popup menu theme.
Future<T?> showRappMenu<T>(
  BuildContext c, {
  required RelativeRect position,
  required List<RappMenuItem<T>> items,
  T? current,
  BoxConstraints? constraints,
  TextStyle? textStyle,
}) {
  final t = RappTokens.of(c);
  final height = controlHeightOf(c);
  // Only the size and font: the colour stays the menu's, so a caption row stays muted.
  final sized = textStyle == null
      ? null
      : TextStyle(
          fontSize: textStyle.fontSize,
          height: textStyle.height,
          fontFamily: textStyle.fontFamily,
          fontFamilyFallback: textStyle.fontFamilyFallback,
        );
  return showMenu<T>(
    context: c,
    position: position,
    constraints: constraints,
    items: [
      for (final it in items)
        if (it.divider)
          const PopupMenuDivider()
        else
          PopupMenuItem<T>(
            key: it.key,
            value: it.value,
            enabled: it.enabled,
            height: height,
            child: Builder(builder: (row) {
              final body = Row(children: [
                if (current != null) ...[
                  SizedBox(
                    width: 18,
                    child: it.value == current ? Icon(Icons.check, size: 18, color: t.text) : null,
                  ),
                  const SizedBox(width: 8),
                ],
                if (it.lead != null) ...[it.lead!, const SizedBox(width: 10)],
                Expanded(child: Text(it.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (it.trailing != null) it.trailing!,
              ]);
              final secondary = it.onSecondaryTapUp;
              final Widget row0 = secondary == null
                  ? body
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTapUp: (d) => secondary(row, d),
                      child: body,
                    );
              return sized == null ? row0 : DefaultTextStyle.merge(style: sized, child: row0);
            }),
          ),
    ],
  );
}

/// The dropdown box: [label] (which may lead with its own icon) with a down arrow. At rest a thin line border; while its
/// menu is open, or when [selected], the raised fill, a text-colour border and semibold text. Opening calls
/// [showRappMenu] under the box; with a non-null [current] it is a pick-one menu.
///
/// [key] goes on the inner [InkWell], not on the widget itself, so a finder by that key matches exactly one
/// widget (the box's tap target) instead of the dropdown and its InkWell both.
class RappDropdown<T> extends StatefulWidget {
  // ignore: use_key_in_widget_constructors
  const RappDropdown({
    Key? key,
    required this.label,
    this.current,
    required this.items,
    required this.onSelected,
    this.selected = false,
    this.minWidth,
    this.dim = false,
    this.expand = false,
    this.arrow = true,
    this.enabled = true,
    this.padding,
    this.menuConstraints,
    this.semanticLabel,
    this.textStyle,
    this.semanticSelected,
    this.center = false,
  }) : _boxKey = key;

  final Key? _boxKey;
  final Widget label;
  final T? current;
  final List<RappMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final bool selected;
  final double? minWidth;

  /// The label is drawn in muted (an inherited value).
  final bool dim;

  /// Fill the width the parent gives and put the arrow at its right end.
  final bool expand;

  /// Show the arrow; off where a short label has no room for it.
  final bool arrow;

  /// Off: the box is drawn but does not open.
  final bool enabled;

  /// What assistive tech reads for the box; without it the label's own text is read.
  final String? semanticLabel;

  /// A text style for the label and the menu rows (size, height); the colour and the open-state weight stay
  /// the box's own.
  final TextStyle? textStyle;

  /// Whether assistive tech hears "selected". Default: [selected] on a pick-one box whose [current] is set.
  final bool? semanticSelected;

  /// Centre the label in a box wider than it (a count with no arrow).
  final bool center;

  /// Replaces the box's own padding (left 12, right 6).
  final EdgeInsets? padding;

  /// The menu's width bounds given the box's width. Default: at least 112 and the box, at most 280 or the box.
  final BoxConstraints Function(double box)? menuConstraints;

  @override
  State<RappDropdown<T>> createState() => _RappDropdownState<T>();
}

class _RappDropdownState<T> extends State<RappDropdown<T>> {
  bool _open = false;

  Future<void> _show(BuildContext box) async {
    if (widget.items.isEmpty) return;
    final render = box.findRenderObject() as RenderBox;
    final at = render.localToGlobal(Offset(0, render.size.height));
    setState(() => _open = true);
    final pick = await showRappMenu<T>(
      box,
      position: menuAt(box, at),
      items: widget.items,
      current: widget.current,
      textStyle: widget.textStyle,
      constraints: widget.menuConstraints?.call(render.size.width) ??
          BoxConstraints(minWidth: math.max(render.size.width, 112), maxWidth: math.max(render.size.width, 280)),
    );
    if (mounted) setState(() => _open = false);
    if (pick != null && mounted) widget.onSelected(pick);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final radius = BorderRadius.circular(t.r);
    // An action menu's box stays plain while its menu is open.
    final strong = widget.selected || (_open && widget.current != null);
    final color = widget.dim ? t.muted : t.text;
    final label = DefaultTextStyle.merge(
      style: (widget.textStyle ?? const TextStyle()).copyWith(
        color: color,
        fontWeight: strong ? FontWeight.w600 : widget.textStyle?.fontWeight,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: widget.label,
    );
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      selected: widget.semanticSelected ?? (widget.selected && widget.current != null),
      child: Material(
        type: MaterialType.transparency,
        child: Builder(
          builder: (box) => InkWell(
            key: widget._boxKey,
            onTap: widget.enabled ? () => _show(box) : null,
            borderRadius: radius,
            child: Container(
              constraints: BoxConstraints(minHeight: controlHeightOf(context), minWidth: widget.minWidth ?? 0),
              padding: widget.padding ?? const EdgeInsets.only(left: 12, right: 6),
              decoration: strong ? t.raiseBox(border: t.text) : BoxDecoration(borderRadius: radius, border: Border.all(color: t.line)),
              child: Row(
                  mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
                  mainAxisAlignment: widget.center ? MainAxisAlignment.center : MainAxisAlignment.start,
                  children: [
                widget.expand ? Expanded(child: label) : Flexible(child: label),
                if (widget.arrow) Icon(Icons.arrow_drop_down, size: 18, color: t.muted),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
