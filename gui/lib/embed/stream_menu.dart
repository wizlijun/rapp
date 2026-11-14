// The top bar's three menus (R5, R13, R22), each a popover a pick closes:
// - 本机 (💻): session actions, the remote clipboard, the remote input method, the input-box mark,
//   app 配置…;
// - 远程 (🖥): the remote app's mirrored menus, nothing else;
// - 流量优化 (the traffic label): stream presets and settings.
// A bar too narrow for three buttons keeps the traffic label alone, with all three parts in it.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../ui/controls.dart';
import '../ui/corner_popover.dart';
import '../ui/resources_state.dart';
import '../ui/session_model.dart';
import '../ui/tokens.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'stream_choice.dart';
import 'traffic_label.dart';

/// Which parts a menu shows.
enum MenuPart { session, remote, stream }

const allMenuParts = {MenuPart.session, MenuPart.remote, MenuPart.stream};

/// Width a 本机 or 远程 button takes in a wide bar (icon, word, arrow); a narrow one is 48.
const menuButtonWidth = 88.0;

/// A corner button with its menu hanging under it: the traffic label for a menu with the stream
/// part, else the 本机 or 远程 button.
class StreamMenuAnchor extends StatefulWidget {
  const StreamMenuAnchor({
    super.key,
    required this.port,
    required this.session,
    required this.path,
    required this.status,
    required this.disconnected,
    this.reconnecting = false,
    this.reconnectWord = '重连',
    required this.onDisconnect,
    required this.onReconnect,
    required this.onEnd,
    this.onToggleDetach,
    this.onRememberStream,
    this.onOpenProfile,
    this.forcedRelay,
    this.onToggleRoute,
    this.onMarkInput,
    this.onClearInput,
    this.parts = allMenuParts,
    required this.open,
    required this.onToggle,
    required this.onClose,
    required this.clips,
    required this.canCopy,
    required this.canInsert,
    required this.onCopy,
    required this.onAllClips,
    this.compact = false,
    this.net,
  });

  /// Bars only, no rate text (narrow top bar).
  final bool compact;

  /// The link to the relay (`HubClient.net`): splits a relayed session's round trip.
  final NetStatus? net;
  final SessionPort port;
  final RemoteSession session;

  /// This record's clipboard entries from the global list, newest first; the menu shows two (K16).
  final List<ClipEntry> clips;
  final bool Function(ClipEntry) canCopy;

  /// Whether 「插入」 may pick the entry into this session's composer (an entry of this very start).
  final bool Function(ClipEntry) canInsert;
  final void Function(ClipEntry) onCopy;

  /// 「全部剪贴板」: open the resources tab.
  final VoidCallback onAllClips;

  /// Whether the menu is open; the owner decides (the corners are exclusive), the anchor shows it.
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onClose;

  /// The hub's path word (`lan`, `direct`).
  final String path;

  /// The session's state word (`lampWord`), shown beside the path.
  final String status;

  /// The link is down: the menu keeps only the session group (R21).
  final bool disconnected;

  /// A reconnect is under way: the same reduced menu, but 「重连」 gives way to the status.
  final bool reconnecting;

  /// The reconnect item's word: 「拿回来」 for a taken-over session (R13), else 「重连」.
  final String reconnectWord;

  /// 「断开」 and 「重连」; null greys them (no hub to ask).
  final VoidCallback? onDisconnect;
  final VoidCallback? onReconnect;

  /// 「结束会话」 was confirmed.
  final VoidCallback onEnd;

  /// 「分离成独立窗口」/「放回主窗口」 (Task 12); null greys the item.
  final VoidCallback? onToggleDetach;

  /// 「记为这个 app 的默认」 and 「app 配置…」; null greys the item.
  final VoidCallback? onRememberStream;
  final VoidCallback? onOpenProfile;

  /// Whether this session's host is forced onto the relay; null hides 「改走中继」/「恢复自动选路」 (no relay set).
  final bool? forcedRelay;

  /// Flips [forcedRelay]; null greys the item (no hub to ask).
  final VoidCallback? onToggleRoute;

  /// 「标记输入区」 (the next click on the picture marks it) and 「清除输入区标记」.
  final VoidCallback? onMarkInput;
  final VoidCallback? onClearInput;

  final Set<MenuPart> parts;

  @override
  State<StreamMenuAnchor> createState() => _StreamMenuAnchorState();
}

class _StreamMenuAnchorState extends State<StreamMenuAnchor> {
  @override
  Widget build(BuildContext context) {
    final parts = widget.parts;
    final kind = parts.contains(MenuPart.stream) ? 'stream' : (parts.contains(MenuPart.remote) ? 'remote' : 'session');
    return CornerPopover(
      open: widget.open,
      onClose: widget.onClose,
      scrimKey: Key('$kind-menu-scrim'),
      popover: StreamMenu(
        parts: parts,
        onMarkInput: widget.onMarkInput,
        onClearInput: widget.onClearInput,
        port: widget.port,
        session: widget.session,
        path: widget.path,
        status: widget.status,
        disconnected: widget.disconnected,
        reconnecting: widget.reconnecting,
        reconnectWord: widget.reconnectWord,
        onDisconnect: widget.onDisconnect,
        onReconnect: widget.onReconnect,
        onClose: widget.onClose,
        onEnd: widget.onEnd,
        onToggleDetach: widget.onToggleDetach,
        onRememberStream: widget.onRememberStream,
        onOpenProfile: widget.onOpenProfile,
        forcedRelay: widget.forcedRelay,
        onToggleRoute: widget.onToggleRoute,
        clips: widget.clips,
        canCopy: widget.canCopy,
        canInsert: widget.canInsert,
        onCopy: widget.onCopy,
        onAllClips: widget.onAllClips,
        net: widget.net,
      ),
      child: kind != 'stream'
          ? MenuCornerButton(
              key: Key('$kind-menu'),
              remote: kind == 'remote',
              open: widget.open,
              compact: widget.compact,
              onTap: widget.onToggle,
            )
          : ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => TrafficLabel(
          key: const Key('traffic'),
          bytesPerSecond: widget.session.bytesPerSecond,
          word: sessionTrafficWord(
            path: widget.path,
            saving: widget.session.saving,
            wholeMs: widget.session.rttMs,
            net: widget.net,
          ),
          open: widget.open,
          compact: widget.compact,
          onTap: widget.onToggle,
          onSecondaryTap: widget.onToggle,
        ),
      ),
    );
  }
}

/// 💻 本机▾ / 🖥 远程▾ (icon alone when [compact]); the remote one is outlined in the accent colour
/// so it never passes for rapp's own.
class MenuCornerButton extends StatelessWidget {
  const MenuCornerButton(
      {super.key, required this.remote, required this.open, required this.onTap, this.compact = false});

  final bool remote;
  final bool open;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final radius = BorderRadius.circular(t.r);
    final word = remote ? '远程' : '本机';
    final color = remote ? t.accent : t.text;
    final border = open ? t.text : (remote ? t.accent : t.line);
    return Semantics(
      button: true,
      selected: open,
      label: remote ? '远程菜单（远端 app 的菜单）' : '本机菜单（会话、剪贴板、输入法）',
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: remote ? '远程菜单：远端 app 自己的菜单' : '本机菜单：会话、剪贴板、输入法',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            onSecondaryTap: onTap,
            borderRadius: radius,
            child: Container(
              width: compact ? 48 : menuButtonWidth,
              constraints: const BoxConstraints(minHeight: 48),
              decoration: open
                  ? t.raiseBox(border: border)
                  : BoxDecoration(borderRadius: radius, border: Border.all(color: border, width: remote ? 1.5 : 1)),
              child: Center(
                heightFactor: 1, // as tall as the row (48 at least), never the whole parent
                child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(remote ? Icons.desktop_windows_outlined : Icons.laptop_mac, size: 18, color: color),
                  if (!compact) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(word,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(color: color, fontWeight: open ? FontWeight.w600 : FontWeight.w400)),
                    ),
                    Icon(Icons.arrow_drop_down, size: 18, color: t.muted),
                  ],
                ],
              ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The menu's content. [onClose] runs after every pick.
/// The row atop the stream groups while A saves traffic ([RemoteSession.saving]): what it lowered
/// below the pick, as A's ladder does (level 1 caps the rate at 5 fps; level 2 also goes to
/// 双色·灰度), naming only what changed. Null at level 0.
String? savingNote(int level, StreamChoice c) {
  if (level <= 0) return null;
  final parts = [
    if (level >= 2 && c.mode != 'duogray') '双色·灰度',
    if (c.fps > 5) '5 fps',
  ];
  return parts.isEmpty ? '（网络差，暂时省流量）' : '（网络差，暂时降到 ${parts.join(' · ')}）';
}

class StreamMenu extends StatefulWidget {
  const StreamMenu({
    super.key,
    required this.port,
    required this.session,
    required this.path,
    required this.status,
    required this.disconnected,
    this.reconnecting = false,
    this.reconnectWord = '重连',
    required this.onDisconnect,
    required this.onReconnect,
    required this.onClose,
    required this.onEnd,
    this.onToggleDetach,
    this.onRememberStream,
    this.onOpenProfile,
    this.forcedRelay,
    this.onToggleRoute,
    this.onMarkInput,
    this.onClearInput,
    this.parts = allMenuParts,
    required this.clips,
    required this.canCopy,
    required this.canInsert,
    required this.onCopy,
    required this.onAllClips,
    this.net,
  });

  final NetStatus? net;
  final Set<MenuPart> parts;
  final VoidCallback? onMarkInput;
  final VoidCallback? onClearInput;
  final List<ClipEntry> clips;
  final bool Function(ClipEntry) canCopy;

  /// Whether 「插入」 may pick the entry into this session's composer (an entry of this very start).
  final bool Function(ClipEntry) canInsert;
  final void Function(ClipEntry) onCopy;
  final VoidCallback onAllClips;
  final SessionPort port;
  final RemoteSession session;
  final String path;
  final String status;
  final bool disconnected;
  final bool reconnecting;
  final String reconnectWord;
  final VoidCallback? onDisconnect;
  final VoidCallback? onReconnect;
  final VoidCallback onClose;
  final VoidCallback onEnd;
  final VoidCallback? onToggleDetach;
  final VoidCallback? onRememberStream;
  final VoidCallback? onOpenProfile;
  final bool? forcedRelay;
  final VoidCallback? onToggleRoute;

  @override
  State<StreamMenu> createState() => _StreamMenuState();
}

class _StreamMenuState extends State<StreamMenu> {
  final _expanded = <String>{};

  RemoteSession get _s => widget.session;
  Object get _sid => _s.sid;

  void _choose(StreamChoice c) {
    _s.setChoice(c, manual: true);
    widget.onClose();
  }

  void _then(VoidCallback action) {
    action();
    widget.onClose();
  }

  String _pathWord() {
    final w = routeWord(widget.path, forced: widget.forcedRelay == true);
    return w.isEmpty ? widget.path : w;
  }

  String _pathRow() {
    final detail = pathDetail(path: widget.path, wholeMs: _s.rttMs, net: widget.net);
    return ['路径 ${_pathWord()}', widget.status, ?detail].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: _s,
      builder: (context, _) {
        final c = _s.choice;
        final window = _s.currentWindow;
        final reduced = widget.disconnected || widget.reconnecting; // only the session group (R21)
        final parts = widget.parts;
        final all = parts.length == allMenuParts.length;
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (parts.contains(MenuPart.stream)) ...[
                if (!reduced) ..._streamGroups(t, c) else if (!all) const _Item('连接断开时不能调', enabled: false),
              ],
              if (parts.contains(MenuPart.session)) ...[
                ..._sessionGroup(t, window, reduced),
                if (!reduced) ..._localGroups(t),
              ],
              if (parts.contains(MenuPart.remote)) ...[
                if (all) ...[
                  if (!reduced && _s.menu.isNotEmpty) ...[
                    _head(t, '远程菜单'),
                    ..._entries(t, _s.menu, const [], 0),
                  ],
                ] else if (reduced)
                  const _Item('连接断开，远程菜单不可用', enabled: false)
                else if (_s.menu.isEmpty)
                  const _Item('远端 app 还没有菜单', enabled: false)
                else ...[
                  _head(t, '${_s.appName} 的菜单'),
                  ..._entries(t, _s.menu, const [], 0),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  /// 会话: the path and state, disconnect or reconnect, detach, top-left, end.
  List<Widget> _sessionGroup(RappTokens t, int? window, bool reduced) => [
        _head(t, '会话'),
        _Item(_pathRow(), enabled: false),
        if (widget.forcedRelay != null && !widget.reconnecting)
          _Item(
            widget.forcedRelay! ? '恢复自动选路' : '改走中继',
            enabled: widget.onToggleRoute != null,
            // Close first: the switch may reopen this very session.
            onTap: () {
              widget.onClose();
              widget.onToggleRoute!();
            },
          ),
        if (widget.disconnected)
          _Item(widget.reconnectWord, enabled: widget.onReconnect != null, onTap: () => _then(widget.onReconnect!))
        else if (!widget.reconnecting) ...[
          _Item('断开', enabled: widget.onDisconnect != null, onTap: () => _then(widget.onDisconnect!)),
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
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConfirmButton(label: '结束会话', onConfirmed: () => _then(widget.onEnd)),
          ),
        ),
      ];

  /// The live session's own settings: the remote clipboard, its input method, the input box,
  /// app 配置….
  List<Widget> _localGroups(RappTokens t) {
    final src = _s.inputSource;
    final back = _s.lastInputMethod;
    final marked = _s.profile.input != null;
    return [
      _head(t, '远程剪贴板'),
      if (widget.clips.isEmpty) const _Item('（空）', enabled: false),
      for (final e in widget.clips.take(2))
        _Item(
          e.title,
          enabled: widget.canCopy(e),
          onTap: () => _then(() => widget.onCopy(e)),
          trailing: widget.canInsert(e)
              ? _InsertButton(onTap: () => _then(() => widget.port.clipPick(_sid, e.clip, true)))
              : null,
        ),
      if (widget.clips.isNotEmpty) _Item('全部剪贴板', onTap: () => _then(widget.onAllClips)),
      if (src != null) ...[
        _head(t, '远端输入法'),
        _Item('现在：${src.ascii ? '英文（${src.name}）' : src.name}', enabled: false),
        _Item('切到英文', enabled: !src.ascii, onTap: () => _then(() => _s.selectInput(''))),
        if (back != null)
          _Item('切回 ${back.name}', enabled: src.id != back.id, onTap: () => _then(() => _s.selectInput(back.id))),
      ],
      _head(t, '输入区'),
      _Item(marked ? '重新标记输入区（再点一下画面）' : '标记输入区（再点一下画面）',
          enabled: widget.onMarkInput != null, onTap: () => _then(widget.onMarkInput!)),
      if (marked)
        _Item('清除输入区标记', enabled: widget.onClearInput != null, onTap: () => _then(widget.onClearInput!)),
      _Item('app 配置…', enabled: widget.onOpenProfile != null, onTap: () => _then(widget.onOpenProfile!)),
    ];
  }

  /// Presets, mode, density, rate. Not on a dead session (R21).
  List<Widget> _streamGroups(RappTokens t, StreamChoice c) {
    final note = savingNote(_s.saving, c);
    return [
              if (note != null) _Item(note, enabled: false),
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
              _Item('记为这个 app 的默认', enabled: widget.onRememberStream != null, onTap: () => _then(widget.onRememberStream!)),
    ];
  }

  Widget _head(RappTokens t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Text(text, style: TextStyle(color: t.muted, fontSize: 12, letterSpacing: t.labelSpacing * 12)),
      );

  /// The remote app's menu, one level at a time: a title with children opens in place.
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
