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
  });

  final bool open;
  final VoidCallback onClose;
  final Key scrimKey;

  /// The popover's content, 340 wide inside a panel box.
  final Widget popover;

  /// The corner's button.
  final Widget child;

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
                targetAnchor: Alignment.bottomRight,
                followerAnchor: Alignment.topRight,
                offset: const Offset(0, 4),
                child: TapRegion(
                  groupId: cornerTapGroup,
                  onTapOutside: (_) => widget.onClose(),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Container(
                      width: 340,
                      constraints: BoxConstraints(maxHeight: (MediaQuery.sizeOf(context).height - 80).clamp(200, 900)),
                      decoration: t.panelBox(),
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
