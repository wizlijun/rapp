// The stream menu (R5, R13, R22): stream presets and settings, A's clipboard, session actions and
// A's mirrored menus. A popover the user opens from the traffic label; a pick closes it.
import 'package:flutter/material.dart';

import '../ui/controls.dart';
import '../ui/session_model.dart';
import '../ui/tokens.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'stream_choice.dart';
import 'traffic_label.dart';

/// The traffic label with the stream menu hanging under it.
class StreamMenuAnchor extends StatefulWidget {
  const StreamMenuAnchor({
    super.key,
    required this.port,
    required this.session,
    required this.path,
    required this.onEnd,
    this.onToggleDetach,
  });

  final SessionPort port;
  final RemoteSession session;

  /// The hub's path word (`lan`, `direct`, `relay`).
  final String path;

  /// 「结束会话」 was confirmed.
  final VoidCallback onEnd;

  /// 「分离成独立窗口」/「放回主窗口」 (Task 12); null greys the item.
  final VoidCallback? onToggleDetach;

  @override
  State<StreamMenuAnchor> createState() => _StreamMenuAnchorState();
}

class _StreamMenuAnchorState extends State<StreamMenuAnchor> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  bool _open = false;

  void _toggle() {
    setState(() => _open = !_open);
    _open ? _portal.show() : _portal.hide();
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('stream-menu-scrim'),
                behavior: HitTestBehavior.opaque,
                onTap: _close,
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 4),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: 340,
                  constraints: BoxConstraints(maxHeight: (MediaQuery.sizeOf(context).height - 80).clamp(200, 900)),
                  decoration: t.panelBox(),
                  child: StreamMenu(
                    port: widget.port,
                    session: widget.session,
                    path: widget.path,
                    onClose: _close,
                    onEnd: widget.onEnd,
                    onToggleDetach: widget.onToggleDetach,
                  ),
                ),
              ),
            ),
          ],
        ),
        child: ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => TrafficLabel(
            key: const Key('traffic'),
            bytesPerSecond: widget.session.bytesPerSecond,
            open: _open,
            onTap: _toggle,
            onSecondaryTap: _toggle,
          ),
        ),
      ),
    );
  }
}

/// The menu's content. [onClose] runs after every pick.
class StreamMenu extends StatefulWidget {
  const StreamMenu({
    super.key,
    required this.port,
    required this.session,
    required this.path,
    required this.onClose,
    required this.onEnd,
    this.onToggleDetach,
  });

  final SessionPort port;
  final RemoteSession session;
  final String path;
  final VoidCallback onClose;
  final VoidCallback onEnd;
  final VoidCallback? onToggleDetach;

  @override
  State<StreamMenu> createState() => _StreamMenuState();
}

class _StreamMenuState extends State<StreamMenu> {
  bool _allClips = false;
  final _expanded = <String>{};

  RemoteSession get _s => widget.session;
  Object get _sid => _s.sid;

  void _choose(StreamChoice c) {
    _s.setChoice(c);
    widget.onClose();
  }

  void _then(VoidCallback action) {
    action();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: _s,
      builder: (context, _) {
        final c = _s.choice;
        final clips = _s.clips;
        final shown = _allClips ? clips : clips.take(2).toList();
        final window = _s.currentWindow;
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _head(t, '预设'),
              _Item('最省流（双色·灰度 + 自适应 + 1 fps）', checked: c == presetLeast, onTap: () => _choose(presetLeast)),
              _Item('最清晰（高彩 + 原画 + 15 fps）', checked: c == presetSharpest, onTap: () => _choose(presetSharpest)),
              _head(t, '档位'),
              for (final (label, mode) in const [('双色·灰度（文本优化）', 'duogray'), ('双色·彩色', 'duocolor'), ('高彩（图像优化）', 'color16')])
                _Item(label, checked: c.mode == mode, onTap: () => _choose(c.copyWith(mode: mode))),
              _head(t, '密度'),
              for (final (label, d) in const [('省流 1x', 'saver1x'), ('自适应', 'adaptive'), ('原画', 'original')])
                _Item(label, checked: c.density == d, onTap: () => _choose(c.copyWith(density: d))),
              _head(t, '帧率'),
              for (final (label, f) in const [('1 fps', 1), ('5 fps', 5), ('15 fps', 15), ('30 fps（看视频）', 30)])
                _Item(label, checked: c.fps == f, onTap: () => _choose(c.copyWith(fps: f))),
              _head(t, 'A 的剪贴板'),
              if (clips.isEmpty) _Item('（空）', enabled: false),
              for (final r in shown)
                _Item(
                  r.title,
                  enabled: r.pickable,
                  onTap: () => _then(() => widget.port.clipPick(_sid, r.id, false)),
                  trailing: r.pickable
                      ? _InsertButton(onTap: () => _then(() => widget.port.clipPick(_sid, r.id, true)))
                      : null,
                ),
              if (clips.length > 2 && !_allClips) _Item('全部剪贴板', onTap: () => setState(() => _allClips = true)),
              _head(t, '会话'),
              _Item('路径 ${pathLabels[widget.path] ?? widget.path}', enabled: false),
              _Item(
                _s.detached ? '放回主窗口' : '分离成独立窗口',
                enabled: widget.onToggleDetach != null,
                onTap: () => _then(widget.onToggleDetach!),
              ),
              _Item(
                '放左上角',
                enabled: window != null,
                onTap: () => _then(() => widget.port.moveTopLeft(_sid, window!)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConfirmButton(label: '结束会话', onConfirmed: () => _then(widget.onEnd)),
                ),
              ),
              if (_s.menu.isNotEmpty) ...[
                _head(t, 'A 的菜单'),
                ..._entries(t, _s.menu, const [], 0),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _head(RappTokens t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Text(text, style: TextStyle(color: t.muted, fontSize: 12, letterSpacing: t.labelSpacing * 12)),
      );

  /// A's menu, one level at a time: a title with children opens in place.
  List<Widget> _entries(RappTokens t, List<MenuEntry> list, List<int> prefix, int depth) {
    final out = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      final path = [...prefix, i];
      // Like the client's menu bar: top level has no separators or untitled items, and only
      // titles that open. Indices still count what is skipped.
      if (depth == 0 && (e.separator || e.title.isEmpty)) continue;
      if (e.separator) {
        out.add(Divider(height: 9, indent: 16.0 + depth * 16, endIndent: 16, color: t.line));
        continue;
      }
      final key = path.join('/');
      final open = _expanded.contains(key);
      final hasKids = e.children.isNotEmpty;
      if (depth == 0 && !hasKids) {
        out.add(_Item(e.title, enabled: false));
        continue;
      }
      out.add(_Item(
        e.title,
        indent: depth * 16.0,
        enabled: e.enabled,
        checked: e.checked,
        trailing: hasKids
            ? Icon(open ? Icons.expand_less : Icons.chevron_right, size: 18, color: t.muted)
            : (e.shortcut == null ? null : _Shortcut(e.shortcut!)),
        onTap: hasKids
            ? () => setState(() => open ? _expanded.remove(key) : _expanded.add(key))
            : () => _then(() => widget.port.menuPick(_sid, path)),
      ));
      if (hasKids && open) out.addAll(_entries(t, e.children, path, depth + 1));
    }
    return out;
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Text(text,
        style: TextStyle(fontFamily: t.mono, fontFamilyFallback: t.monoFallback, fontSize: 12, color: t.muted));
  }
}

class _InsertButton extends StatelessWidget {
  const _InsertButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(t.r),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text('插入', style: TextStyle(color: t.text, decoration: TextDecoration.underline)),
      ),
    );
  }
}

/// One row: a tick column, the label, an optional trailing widget. Greyed when disabled (no action).
class _Item extends StatelessWidget {
  const _Item(this.label, {this.checked = false, this.enabled = true, this.onTap, this.trailing, this.indent = 0});
  final String label;
  final bool checked;
  final bool enabled;
  final VoidCallback? onTap;
  final Widget? trailing;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final active = enabled && onTap != null;
    final color = enabled ? t.text : t.muted;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: EdgeInsets.only(left: 12 + indent, right: 12),
      child: Row(
        children: [
          SizedBox(width: 24, child: checked ? Icon(Icons.check, size: 18, color: t.text) : null),
          Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: color))),
          ?trailing,
        ],
      ),
    );
    if (!active) {
      return Semantics(enabled: false, selected: checked, label: label, excludeSemantics: true, child: row);
    }
    // A trailing button sits beside the row's own tap target, not inside it.
    return InkWell(onTap: onTap, child: row);
  }
}
