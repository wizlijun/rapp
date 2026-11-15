// The shell both top-bar corners share (the stream menu, 「需要你」): a button, and a popover under it
// while [open]. One rule for closing lives here: a tap anywhere outside the popover and the two
// corner buttons closes it (the other corner's button just switches), a scrim below the bar keeps
// that tap from reaching the picture.
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Both corner buttons and both popovers belong to this group.
final Object cornerTapGroup = Object();

class CornerPopover extends StatefulWidget {
  const CornerPopover({
    super.key,
    required this.open,
    required this.onClose,
    required this.scrimKey,
    required this.popover,
    required this.child,
    this.alignLeft = false,
  });

  final bool open;
  final VoidCallback onClose;
  final Key scrimKey;

  /// The popover's content, 340 wide inside an opaque float box.
  final Widget popover;

  /// The corner's button.
  final Widget child;

  /// Hang from the button's left edge instead of its right; then the popover narrows and moves
  /// left as needed to stay 8 inside the window.
  final bool alignLeft;

  @override
  State<CornerPopover> createState() => _CornerPopoverState();
}

class _CornerPopoverState extends State<CornerPopover> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  // The portal is shown for good (its controller refuses to change while building); what it
  // draws follows [CornerPopover.open], in the same frame as the change.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _portal.show();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) {
          if (!widget.open) return const SizedBox.shrink();
          final screen = MediaQuery.sizeOf(context).width;
          var width = 340.0;
          var dx = 0.0;
          if (widget.alignLeft) {
            width = width.clamp(0.0, (screen - 16).clamp(0.0, double.infinity)).toDouble();
            // The button was laid out in the frame that opened the popover.
            final box = this.context.findRenderObject() as RenderBox?;
            final left = box != null && box.hasSize ? box.localToGlobal(Offset.zero).dx : 0.0;
            dx = -(left + width - (screen - 8)).clamp(0.0, double.infinity).toDouble();
          }
          return Stack(
            children: [
              // Below the bar, so the bar's own buttons stay live (the tap that closes the corner
              // is theirs to use); the picture and the panel never see the closing tap.
              Positioned.fill(
                top: topBarHeight,
                child: GestureDetector(key: widget.scrimKey, behavior: HitTestBehavior.opaque, onTap: widget.onClose),
              ),
              CompositedTransformFollower(
                link: _link,
                targetAnchor: widget.alignLeft ? Alignment.bottomLeft : Alignment.bottomRight,
                followerAnchor: widget.alignLeft ? Alignment.topLeft : Alignment.topRight,
                offset: Offset(dx, 4),
                child: TapRegion(
                  groupId: cornerTapGroup,
                  onTapOutside: (_) => widget.onClose(),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Container(
                      width: width,
                      constraints: BoxConstraints(maxHeight: (MediaQuery.sizeOf(context).height - 80).clamp(200, 900)),
                      decoration: t.floatBox(),
                      child: widget.popover,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: TapRegion(groupId: cornerTapGroup, child: widget.child),
      ),
    );
  }
}
