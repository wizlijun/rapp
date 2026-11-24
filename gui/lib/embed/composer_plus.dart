// The 「＋」 button of the writing panel and the menu above it (spec W13, input dock §5.3): 附件…, 在远端复制,
// 输入历史, 直接回车且隐藏, 大小, the 快捷区 settings, 收起. The same on every platform.
// A terminal's menu: 附件… greyed, no 在远端复制.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../history/history_list.dart';
import '../history/input_history.dart';
import '../pages/phrases_page.dart';
import '../term/term_session_port.dart' show termNoAttach;
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/prefs.dart' show composerZoomMax, composerZoomScales;
import '../ui/tokens.dart';
import 'app_profile.dart';
import 'remote_session.dart';
import 'session_port.dart';

/// macOS modifier bits, as the runner's `key` takes them.
const commandBit = 1048576;
const optionBit = 524288;

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
      required this.state,
      required this.session,
      required this.port,
      required this.onAttach,
      this.onPress,
      this.history,
      this.historyKey,
      this.onAddPhrase,
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

  /// The quick-area prefs the menu's 快捷区 group flips.
  final MainState state;

  final RemoteSession session;
  final SessionPort port;

  /// 「附件…」: the panel asks the runner and applies the result.
  final VoidCallback onAttach;

  /// Any press in the menu (it sits in the overlay, outside the panel's own listener).
  final VoidCallback? onPress;

  /// The input record for 「输入历史」 (no such row without it) and this session's key (`host/app`).
  final InputHistory? history;
  final String? historyKey;

  /// 输入历史's 加到常用语 (iOS); no such item without it.
  final void Function(String text)? onAddPhrase;

  /// 「直接回车且隐藏」 toggled: whether a submit gets a Return after its paste, then hides the panel (the app's afterSend).
  /// No such row without it.
  final ValueChanged<bool>? onReturnAfter;

  /// A terminal session's menu; [port] is then a [TermSessionPort].
  final bool terminal;

  /// A network drop froze the session: the menu's keys and copy go grey and send nothing.
  final bool blocked;

  @override
  State<ComposerPlus> createState() => _ComposerPlusState();
}

class _ComposerPlusState extends State<ComposerPlus> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _group = Object();

  void _close() => _portal.hide();

  /// The menu opens below 「＋」 when the button sits in the upper half of the overlay (a panel moved up
  /// there, floating-composer spec), else above it. Decided once, at open.
  bool _down = false;

  /// The card's tallest height: the room on the side it opens into, less the 8 gap and an 8 margin. Taller content scrolls.
  double _maxHeight = double.infinity;

  void _toggle() {
    if (_portal.isShowing) return _close();
    final box = context.findRenderObject();
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (box is RenderBox && overlay is RenderBox && box.hasSize) {
      final top = box.localToGlobal(Offset.zero, ancestor: overlay).dy;
      _down = top < overlay.size.height / 2;
      final room = _down ? overlay.size.height - (top + box.size.height) : top;
      _maxHeight = (room - 16).clamp(0.0, double.infinity);
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
              onAddPhrase: widget.onAddPhrase,
            ),
          ),
        ),
      ),
    );
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
            if (side != null) ...[const Spacer(), Text(side, style: TextStyle(color: t.muted))],
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
      return RappSwitchRow(
        key: const Key('composer-plus-return'),
        label: '直接回车且隐藏',
        note: '贴完按回车再收起',
        value: on,
        onChanged: widget.onReturnAfter,
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
                    textAlign: TextAlign.end, style: TextStyle(color: t.muted)),
              ),
            ],
          ),
        ),
      );

  /// The 快捷区 group: three switches (the menu stays open) and the phrases page.
  Widget _quickGroup(RappTokens t) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final st = widget.state;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('快捷区', key: const Key('composer-plus-quick'), style: TextStyle(color: t.muted)),
          ),
          RappSwitchRow(
              key: const Key('quick-auto-hide'),
              label: '打字后自动收起',
              value: st.quickAutoHide,
              onChanged: st.setQuickAutoHide),
          RappSwitchRow(
              key: const Key('quick-phrase-strip'),
              label: '显示常用语条',
              value: st.prefs.phraseStrip,
              onChanged: st.setPhraseStrip),
          RappSwitchRow(
              key: const Key('quick-more'), label: '更多按键', value: st.prefs.keyBarMore, onChanged: st.setKeyBarMore),
          InkWell(
            key: const Key('quick-edit-phrases'),
            onTap: () {
              _close();
              openPhrasesPage(this.context, st);
            },
            borderRadius: BorderRadius.circular(t.r),
            child: SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(alignment: Alignment.centerLeft, child: Text('编辑常用语…', style: TextStyle(color: t.text))),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _menu(BuildContext context) {
    final t = RappTokens.of(context);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    const rowGap = SizedBox(height: 6);
    final term = widget.terminal;
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
                constraints: BoxConstraints(maxHeight: _maxHeight),
                child: SingleChildScrollView(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (term)
                      _row(t, '附件…', termNoAttach, null)
                    else
                      _row(t, '附件…', '也可以直接粘贴', () {
                        _close();
                        widget.onAttach();
                      }),
                    rowGap,
                    if (!term) ...[_row(t, '在远端复制', mac ? '⌘C' : 'Ctrl+C', widget.blocked ? null : _copy), rowGap],
                    if (widget.history != null) ...[_row(t, '输入历史', null, _openHistory), rowGap],
                    if (widget.onReturnAfter != null) ...[_returnAfter(t), rowGap],
                    if (widget.zoom != null && widget.onZoom != null) ...[_zoomRow(t), rowGap],
                    _quickGroup(t),
                    rowGap,
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
                              Text('Esc', style: TextStyle(color: t.muted)),
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
