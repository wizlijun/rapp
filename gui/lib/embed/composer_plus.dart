// The 「＋」 button of the writing panel and the menu above it (spec W9, W13): 附件…, 在远端复制,
// the keys that go straight to A, 收起. The ⌘ and ⌥ stick for one key; a key does not close the menu.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ui/controls.dart';
import '../ui/tokens.dart';
import 'remote_session.dart';
import 'session_port.dart';

/// macOS modifier bits, as the runner's `key` takes them.
const commandBit = 1048576;
const optionBit = 524288;

/// The keys grid (W9 order): label, key code, and the modifier bit for the sticky ones.
const composerKeys = <(String, int, int?)>[
  ('Esc', 53, null),
  ('Tab', 48, null),
  ('⌘', 0, commandBit),
  ('⌥', 0, optionBit),
  ('删除', 51, null),
  ('←', 123, null),
  ('↓', 125, null),
  ('↑', 126, null),
  ('→', 124, null),
  ('回车', 36, null),
];

class ComposerPlus extends StatefulWidget {
  const ComposerPlus({super.key, required this.session, required this.port, required this.onAttach, this.onPress});

  final RemoteSession session;
  final SessionPort port;

  /// 「附件…」: the panel asks the runner and applies the result.
  final VoidCallback onAttach;

  /// Any press in the menu (it sits in the overlay, outside the panel's own listener).
  final VoidCallback? onPress;

  @override
  State<ComposerPlus> createState() => _ComposerPlusState();
}

class _ComposerPlusState extends State<ComposerPlus> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _group = Object();
  int _sticky = 0;

  void _close() => _portal.hide();

  void _key(int code) {
    widget.port.key(widget.session.sid, code, _sticky);
    setState(() => _sticky = 0);
  }

  void _copy() {
    widget.port.key(widget.session.sid, 8, commandBit); // ⌘C on A
    widget.session.composer.copyPressed();
    _close();
  }

  Widget _row(RappTokens t, String label, String? side, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(t.r),
    child: SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(label, style: TextStyle(color: t.text)),
            if (side != null) ...[const Spacer(), Text(side, style: TextStyle(color: t.muted, fontSize: 12))],
          ],
        ),
      ),
    ),
  );

  Widget _keyCell(RappTokens t, (String, int, int?) k) {
    final (label, code, bit) = k;
    final on = bit != null && _sticky & bit != 0;
    return Semantics(
      button: true,
      selected: bit == null ? null : on,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        key: bit == null ? null : ValueKey('sticky-$label'),
        onTap: bit == null ? () => _key(code) : () => setState(() => _sticky ^= bit),
        borderRadius: BorderRadius.circular(t.r),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: on
              ? BoxDecoration(color: t.text, borderRadius: BorderRadius.circular(t.r))
              : t.raiseBox().copyWith(border: Border.all(color: t.line)),
          child: Text(label, style: TextStyle(color: on ? t.bg : t.text)),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final t = RappTokens.of(context);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    const rowGap = SizedBox(height: 6);
    final rows = <Widget>[
      for (var i = 0; i < composerKeys.length; i += 5)
        Row(
          children: [
            for (var j = i; j < i + 5; j++) ...[
              if (j > i) const SizedBox(width: 6),
              Expanded(child: _keyCell(t, composerKeys[j])),
            ],
          ],
        ),
    ];
    // The overlay gives tight constraints; the Align lets the follower be the menu's size.
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.bottomRight,
        offset: const Offset(0, -8),
        child: TapRegion(
          groupId: _group,
          child: Listener(
            onPointerDown: (_) => widget.onPress?.call(),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: const Key('composer-plus-menu'),
                width: 300,
                decoration: t.panelBox(),
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _row(t, '附件…', '也可以直接粘贴', () {
                      _close();
                      widget.onAttach();
                    }),
                    rowGap,
                    _row(t, '在远端复制', mac ? '⌘C' : 'Ctrl+C', _copy),
                    rowGap,
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text('按键 · 直接发给远端', style: TextStyle(color: t.muted, fontSize: 12)),
                    ),
                    rowGap,
                    for (final r in rows) ...[r, rowGap],
                    _row(t, '收起', null, () {
                      _close();
                      widget.session.composer.collapse();
                    }),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _menu,
      child: TapRegion(
        groupId: _group,
        onTapOutside: (_) => _close(),
        child: CompositedTransformTarget(
          link: _link,
          child: RappButton.secondary(
            key: const Key('composer-plus'),
            label: '＋',
            semanticLabel: '更多',
            icon: Icons.add,
            onPressed: _portal.toggle,
          ),
        ),
      ),
    );
  }
}
