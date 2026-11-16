// The 「＋」 button of the writing panel and the menu above it (spec W9, W13): 附件…, 在远端复制,
// the keys that go straight to A, 收起. The ⌘ and ⌥ stick for one key; a key does not close the menu.
// A terminal's menu: 附件… greyed, no 在远端复制, and 15 keys by their terminal names (no sticky keys).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../history/history_list.dart';
import '../history/input_history.dart';
import '../term/term_session_port.dart';
import '../ui/controls.dart';
import '../ui/prefs.dart' show composerZoomMax, composerZoomScales;
import '../ui/tokens.dart';
import 'app_profile.dart';
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

/// A terminal's keys grid: label, and the key name the pane gets (删除 is Backspace).
const termComposerKeys = <(String, String)>[
  ('Esc', 'Esc'),
  ('Tab', 'Tab'),
  ('⇧Tab', 'Shift-Tab'),
  ('删除', 'Backspace'),
  ('回车', 'Enter'),
  ('←', 'Left'),
  ('↓', 'Down'),
  ('↑', 'Up'),
  ('→', 'Right'),
  ('⌃C', 'Ctrl-C'),
  ('⌃D', 'Ctrl-D'),
  ('⌃L', 'Ctrl-L'),
  ('⌃R', 'Ctrl-R'),
  ('PgUp', 'PageUp'),
  ('PgDn', 'PageDown'),
];

/// 放进输入框: the writing panel opens, the text goes in at the caret and the field takes focus.
void putIntoComposer(RemoteSession s, String text) {
  final c = s.composer;
  c.open = true;
  c.insert(text);
  c.wantFocus();
}

class ComposerPlus extends StatefulWidget {
  const ComposerPlus(
      {super.key,
      required this.session,
      required this.port,
      required this.onAttach,
      this.onPress,
      this.history,
      this.historyKey,
      this.onReturnAfter,
      this.terminal = false,
      this.blocked = false,
      this.scale = 1,
      this.zoom,
      this.onZoom});

  /// The panel's zoom: the ＋ button's size.
  final double scale;

  /// The zoom step (0 is the default) and its setter, for the menu's slider; no slider without them.
  final int? zoom;
  final ValueChanged<int>? onZoom;

  final RemoteSession session;
  final SessionPort port;

  /// 「附件…」: the panel asks the runner and applies the result.
  final VoidCallback onAttach;

  /// Any press in the menu (it sits in the overlay, outside the panel's own listener).
  final VoidCallback? onPress;

  /// The input record for 「输入历史」 (no such row without it) and this session's key (`host/app`).
  final InputHistory? history;
  final String? historyKey;

  /// 「直接回车且隐藏」 toggled: whether a submit gets a Return after its paste, then hides the panel (the app's afterSend).
  /// No such row without it.
  final ValueChanged<bool>? onReturnAfter;

  /// A terminal session's menu; [port] is then a [TermSessionPort].
  final bool terminal;

  /// A network drop froze the session: the menu's keys, copy and attach go grey and send nothing.
  final bool blocked;

  @override
  State<ComposerPlus> createState() => _ComposerPlusState();
}

class _ComposerPlusState extends State<ComposerPlus> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _group = Object();
  int _sticky = 0;

  /// The menu goes, and an armed ⌘ or ⌥ with it.
  void _close() {
    _portal.hide();
    if (_sticky != 0) setState(() => _sticky = 0);
  }

  /// The menu opens below 「＋」 when the button sits in the upper half of the overlay (a panel moved up
  /// there, floating-composer spec), else above it. Decided once, at open.
  bool _down = false;

  void _toggle() {
    if (_portal.isShowing) return _close();
    final box = context.findRenderObject();
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (box is RenderBox && overlay is RenderBox && box.hasSize) {
      _down = box.localToGlobal(Offset.zero, ancestor: overlay).dy < overlay.size.height / 2;
    }
    _portal.show();
  }

  void _openHistory() {
    _close();
    final h = widget.history!;
    final key = widget.historyKey;
    showDialog<void>(
      context: context,
      builder: (dialog) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: InputHistoryList(
              history: h,
              session: key,
              host: key?.split('/').first,
              onPut: (text) {
                putIntoComposer(widget.session, text);
                Navigator.of(dialog).pop();
              },
            ),
          ),
        ),
      ),
    );
  }

  void _key(int code) {
    widget.port.key(widget.session.sid, code, _sticky);
    setState(() => _sticky = 0);
  }

  void _copy() {
    widget.port.key(widget.session.sid, 8, commandBit); // ⌘C on A
    widget.session.composer.copyPressed();
    _close();
  }

  /// A menu row; greyed and not pressable without [onTap].
  Widget _row(RappTokens t, String label, String? side, VoidCallback? onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(t.r),
    child: SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(label, style: TextStyle(color: onTap == null ? t.muted : t.text)),
            if (side != null) ...[const Spacer(), Text(side, style: TextStyle(color: t.muted, fontSize: 12))],
          ],
        ),
      ),
    ),
  );

  /// A check row; the menu stays open so the new state shows. Follows the session's profile.
  Widget _returnAfter(RappTokens t) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final on = widget.session.profile.afterSend == AfterSend.pressReturn;
      return Semantics(
        checked: on,
        child: InkWell(
          key: const Key('composer-plus-return'),
          onTap: () => widget.onReturnAfter!(!on),
          borderRadius: BorderRadius.circular(t.r),
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text('直接回车且隐藏', style: TextStyle(color: t.text)),
                  const SizedBox(width: 8),
                  Text('贴完按回车再收起', style: TextStyle(color: t.muted, fontSize: 12)),
                  const Spacer(),
                  Icon(on ? Icons.check_box : Icons.check_box_outline_blank, size: 20, color: on ? t.accent : t.muted),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  /// 「大小」: a slider over the zoom steps (what ⌘= / ⌘- / ⌘0 step through); 默认 sits at its left end.
  Widget _zoomRow(RappTokens t) => SizedBox(
        key: const Key('composer-plus-zoom'),
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text('大小', style: TextStyle(color: t.text)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: t.accent,
                    inactiveTrackColor: t.line,
                    thumbColor: t.accent,
                    overlayShape: SliderComponentShape.noOverlay,
                    trackHeight: 3,
                  ),
                  child: Slider(
                    value: widget.zoom!.toDouble(),
                    min: 0,
                    max: composerZoomMax.toDouble(),
                    divisions: composerZoomMax,
                    semanticFormatterCallback: (v) => '${(composerZoomScales[v.round()] * 100).round()}%',
                    onChanged: (v) => widget.onZoom!(v.round()),
                  ),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${(composerZoomScales[widget.zoom!] * 100).round()}%',
                    textAlign: TextAlign.end, style: TextStyle(color: t.muted, fontSize: 12)),
              ),
            ],
          ),
        ),
      );

  Widget _keyCell(RappTokens t, (String, int, int?) k) {
    final (label, code, bit) = k;
    return _cell(t, label, bit,
        bit != null ? () => setState(() => _sticky ^= bit) : widget.blocked ? null : () => _key(code));
  }

  Widget _termKeyCell(RappTokens t, (String, String) k) {
    final (label, name) = k;
    return _cell(t, label, null,
        widget.blocked ? null : () => (widget.port as TermSessionPort).sendKeys(widget.session.sid, [name]));
  }

  /// A key; [bit] for a sticky one.
  Widget _cell(RappTokens t, String label, int? bit, VoidCallback? onTap) {
    final on = bit != null && _sticky & bit != 0;
    return Semantics(
      button: true,
      selected: bit == null ? null : on,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        key: bit == null ? null : ValueKey('sticky-$label'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(t.r),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: on
              ? BoxDecoration(color: t.text, borderRadius: BorderRadius.circular(t.r))
              : t.raiseBox().copyWith(border: Border.all(color: t.line)),
          child: Text(label, style: TextStyle(color: on ? t.bg : onTap == null ? t.muted : t.text)),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final t = RappTokens.of(context);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    const rowGap = SizedBox(height: 6);
    final term = widget.terminal;
    final cells = term
        ? [for (final k in termComposerKeys) _termKeyCell(t, k)]
        : [for (final k in composerKeys) _keyCell(t, k)];
    final rows = <Widget>[
      for (var i = 0; i < cells.length; i += 5)
        Row(
          children: [
            for (var j = i; j < i + 5; j++) ...[
              if (j > i) const SizedBox(width: 6),
              Expanded(child: cells[j]),
            ],
          ],
        ),
    ];
    // The overlay gives tight constraints; the Align lets the follower be the menu's size.
    final menu = Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: _down ? Alignment.bottomRight : Alignment.topRight,
        followerAnchor: _down ? Alignment.topRight : Alignment.bottomRight,
        offset: Offset(0, _down ? 8 : -8),
        child: TapRegion(
          groupId: _group,
          child: Listener(
            onPointerDown: (_) => widget.onPress?.call(),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: const Key('composer-plus-menu'),
                width: 300,
                decoration: t.floatBox(),
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (term)
                      _row(t, '附件…', termNoAttach, null)
                    else
                      _row(t, '附件…', '也可以直接粘贴', widget.blocked ? null : () {
                        _close();
                        widget.onAttach();
                      }),
                    rowGap,
                    if (!term) ...[_row(t, '在远端复制', mac ? '⌘C' : 'Ctrl+C', widget.blocked ? null : _copy), rowGap],
                    if (widget.history != null) ...[_row(t, '输入历史', null, _openHistory), rowGap],
                    if (widget.onReturnAfter != null) ...[_returnAfter(t), rowGap],
                    if (widget.zoom != null && widget.onZoom != null) ...[_zoomRow(t), rowGap],
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text('按键 · 直接发给远端', style: TextStyle(color: t.muted, fontSize: 12)),
                    ),
                    rowGap,
                    for (final r in rows) ...[r, rowGap],
                    // On the right, next to ＋, so collapsing is a short move; Esc in the editor does the same.
                    InkWell(
                      key: const Key('composer-plus-collapse'),
                      onTap: () {
                        _close();
                        widget.session.composer.collapse();
                      },
                      borderRadius: BorderRadius.circular(t.r),
                      child: SizedBox(
                        height: 48,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              const Spacer(),
                              Text('Esc', style: TextStyle(color: t.muted, fontSize: 12)),
                              const SizedBox(width: 8),
                              Text('收起', style: TextStyle(color: t.text)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // A tap outside is the menu's: a barrier under it takes the tap, so it never reaches A.
    // The menu keeps its own size at any panel zoom: its rows are laid out for the default text.
    return MediaQuery.withNoTextScaling(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _close),
          ),
          menu,
        ],
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
            size: 40 * widget.scale,
            onPressed: _toggle,
          ),
        ),
      ),
    );
  }
}
