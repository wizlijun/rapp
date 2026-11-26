// The top bar's three menus (R5, R13, R22), each a popover a pick closes:
// - 本机 (💻): session actions, the remote clipboard, the remote input method, the input-box mark,
//   app 配置…;
// - 远程 (🖥): the remote app's mirrored menus, nothing else;
// - 流量优化 (the traffic label): stream presets and settings.
// A bar too narrow for three buttons keeps the traffic label alone, with all three parts in it.
// A terminal session (its port is a TermSessionPort) has 「本机 · 跟着我的窗口」 for traffic and only
// the session group besides.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../ui/controls.dart';
import '../ui/corner_popover.dart';
import '../ui/net_marker.dart' show netTooltip;
import '../ui/resources_state.dart';
import '../ui/session_model.dart';
import '../term/term_session_port.dart';
import '../ui/tokens.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'stream_choice.dart';
import 'traffic_label.dart';

/// Which parts a menu shows.
enum MenuPart { session, remote, stream }

const allMenuParts = {MenuPart.session, MenuPart.remote, MenuPart.stream};

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
    this.onEndTerm,
    this.onToggleDetach,
    this.onRememberStream,
    this.onOpenProfile,
    this.forcedRelay,
    this.onToggleRoute,
    this.onMarkInput,
    this.onClearInput,
    this.termFit = true,
    this.onTermFit,
    this.parts = allMenuParts,
    required this.open,
    required this.onToggle,
    required this.onClose,
    required this.clips,
    required this.canCopy,
    required this.canInsert,
    required this.onCopy,
    required this.onAllClips,
    this.net,
    this.addTargets = const [],
    this.onAddToProject,
    this.canSaveProject = false,
    this.onSaveProject,
  });

  /// The link to the relay (`HubClient.net`): splits a relayed session's round trip, and its words
  /// open the traffic menu.
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

  /// A text terminal's 「结束终端」 (for good, on its device); null leaves it out (an old device cannot).
  final VoidCallback? onEndTerm;

  /// A terminal's 「本机 · 跟着我的窗口」: whether it is on, and the switch (null greys it).
  final bool termFit;
  final ValueChanged<bool>? onTermFit;

  final Set<MenuPart> parts;

  /// 「加入项目」: the projects (id, name) this session is not in yet, the pick, and 「存成项目」
  /// (greyed when [canSaveProject] is false). A null [onSaveProject] leaves 「加入项目」 out.
  final List<(String, String)> addTargets;
  final void Function(String projectId)? onAddToProject;
  final bool canSaveProject;
  final void Function(String name)? onSaveProject;

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
        termFit: widget.termFit,
        onTermFit: widget.onTermFit,
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
        onEndTerm: widget.onEndTerm,
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
        addTargets: widget.addTargets,
        onAddToProject: widget.onAddToProject,
        canSaveProject: widget.canSaveProject,
        onSaveProject: widget.onSaveProject,
      ),
      child: kind != 'stream'
          ? MenuCornerButton(
              key: Key('$kind-menu'),
              remote: kind == 'remote',
              open: widget.open,
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
          onTap: widget.onToggle,
          onSecondaryTap: widget.onToggle,
        ),
      ),
    );
  }
}

/// ⋯ 本机 / ≡ 远程, icons only, 48 wide, no box until open; the remote icon is in the accent colour
/// so it never passes for rApp's own.
class MenuCornerButton extends StatelessWidget {
  const MenuCornerButton(
      {super.key, required this.remote, required this.open, required this.onTap});

  final bool remote;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final radius = BorderRadius.circular(t.r);
    final color = remote ? t.accent : t.text;
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
              width: 48,
              constraints: const BoxConstraints(minHeight: 48),
              decoration: open
                  ? t.raiseBox(border: t.text)
                  : BoxDecoration(borderRadius: radius, border: Border.all(color: Colors.transparent)),
              child: Center(
                heightFactor: 1, // as tall as the row (48 at least), never the whole parent
                child: Icon(remote ? Icons.menu : Icons.more_horiz, size: 20, color: color),
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
    this.onEndTerm,
    this.onToggleDetach,
    this.onRememberStream,
    this.onOpenProfile,
    this.forcedRelay,
    this.onToggleRoute,
    this.onMarkInput,
    this.onClearInput,
    this.termFit = true,
    this.onTermFit,
    this.parts = allMenuParts,
    required this.clips,
    required this.canCopy,
    required this.canInsert,
    required this.onCopy,
    required this.onAllClips,
    this.net,
    this.addTargets = const [],
    this.onAddToProject,
    this.canSaveProject = false,
    this.onSaveProject,
  });

  final NetStatus? net;
  final Set<MenuPart> parts;
  final VoidCallback? onEndTerm;
  final VoidCallback? onMarkInput;
  final VoidCallback? onClearInput;
  final bool termFit;
  final ValueChanged<bool>? onTermFit;
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

  /// 「加入项目」: the projects (id, name) this session is not in yet, the pick, and 「存成项目」
  /// (greyed when [canSaveProject] is false). A null [onSaveProject] leaves 「加入项目」 out.
  final List<(String, String)> addTargets;
  final void Function(String projectId)? onAddToProject;
  final bool canSaveProject;
  final void Function(String name)? onSaveProject;

  @override
  State<StreamMenu> createState() => _StreamMenuState();
}

class _StreamMenuState extends State<StreamMenu> {
  final _expanded = <String>{};
  bool _adding = false;
  bool _naming = false;
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

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
        final port = widget.port;
        final term = port is TermSessionPort;
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (parts.contains(MenuPart.stream)) ...[
                ..._statusRows(reduced),
                if (!reduced && term) ...[
                  _head(t, '本机'),
                  _Item(
                    '跟着我的窗口',
                    key: const Key('term-fit'),
                    checked: widget.termFit,
                    enabled: widget.onTermFit != null,
                    onTap: () => _then(() => widget.onTermFit!(!widget.termFit)),
                  ),
                ] else if (!reduced)
                  ..._streamGroups(t, c)
                else if (!all)
                  const _Item('连接断开时不能调', enabled: false),
              ],
              if (parts.contains(MenuPart.session)) ...[
                ..._sessionGroup(t, window, reduced, term),
                if (!reduced && !term) ..._localGroups(t),
              ],
              if (parts.contains(MenuPart.remote) && !term) ...[
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

  /// What the top bar's bars and network mark stand for, atop the traffic menu: the rate and what is
  /// weak (not on a dead session), then the link to the relay ([netTooltip]'s lines).
  List<Widget> _statusRows(bool reduced) {
    final net = widget.net;
    return [
      if (!reduced)
        _Item(
          trafficRow(
            _s.bytesPerSecond,
            sessionTrafficWord(path: widget.path, saving: _s.saving, wholeMs: _s.rttMs, net: net),
          ),
          key: const Key('menu-traffic'),
          enabled: false,
        ),
      if (net != null)
        for (final (i, line) in netTooltip(net, path: widget.path).split('\n').indexed)
          _Item(line, key: Key('menu-net-$i'), enabled: false),
    ];
  }

  /// 会话: the path and state, disconnect or reconnect, detach, top-left (not for a [term]), end.
  List<Widget> _sessionGroup(RappTokens t, int? window, bool reduced, bool term) => [
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
          if (!term) ...[
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
        ],
        if (widget.onSaveProject != null) ...[
          _Item('加入项目', key: const Key('add-to-project'), onTap: () => setState(() => _adding = !_adding)),
          if (_adding) ...[
            for (final (id, name) in widget.addTargets)
              _Item(name, key: Key('add-to-$id'), indent: 24, onTap: () => _then(() => widget.onAddToProject!(id))),
            if (_naming)
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 4, 12, 4),
                child: TextField(
                  key: const Key('save-project-name'),
                  controller: _name,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: '存成项目',
                  ),
                  onSubmitted: (v) {
                    if (v.trim().isEmpty) return;
                    _then(() => widget.onSaveProject!(v));
                  },
                ),
              )
            else
              _Item(
                '存成项目',
                key: const Key('add-save-project'),
                indent: 24,
                enabled: widget.canSaveProject,
                onTap: () => setState(() => _naming = true),
              ),
          ],
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            // A text terminal's 「关闭」 only stops viewing it; 「结束终端」 ends it on its device.
            child: Wrap(spacing: 8, runSpacing: 4, children: [
              ConfirmButton(label: term ? '关闭' : '结束会话', onConfirmed: () => _then(widget.onEnd)),
              if (term && widget.onEndTerm != null)
                RappButton.danger(
                    key: const Key('end-term'), label: '结束终端', onPressed: () => _then(widget.onEndTerm!)),
            ]),
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
          _Item('切回 ${back.name}',
              enabled: src.id != back.id,
              onTap: () => _then(() {
                    _s.setAutoEnglish(false);
                    _s.selectInput(back.id);
                  })),
        if (!_s.autoEnglish) _Item('直接打字不会自动切英文，打开写作版后恢复', enabled: false),
      ],
      _head(t, '输入区'),
      _Item(marked ? '重新标记输入区（再点一下画面）' : '标记输入区（再点一下画面）',
          enabled: widget.onMarkInput != null, onTap: () => _then(widget.onMarkInput!)),
      if (marked)
        _Item('清除输入区标记', enabled: widget.onClearInput != null, onTap: () => _then(widget.onClearInput!)),
      // Rules that may be out of date: said in the menu, never as a pop-up.
      if (_s.appState?.stale == true)
        _Item(_s.appState!.health == 'switched' ? '状态规则自动换了变体' : '状态规则可能过期', enabled: false),
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
              _Item('智能（按网络和焦点自动调）', checked: c == presetSmart, onTap: () => _choose(presetSmart)),
              _Item('最清晰（高彩 + 原画 + 15 fps）', checked: c == presetSharpest, onTap: () => _choose(presetSharpest)),
              _head(t, '档位'),
              for (final (label, mode) in const [('双色·灰度（文本优化）', 'duogray'), ('双色·彩色', 'duocolor'), ('高彩（图像优化）', 'color16')])
                _Item(label, checked: !c.smart && c.mode == mode, onTap: () => _choose(c.copyWith(mode: mode))),
              _head(t, '密度'),
              for (final (label, d) in const [('省流 1x', 'saver1x'), ('自适应', 'adaptive'), ('原画', 'original')])
                _Item(label, checked: !c.smart && c.density == d, onTap: () => _choose(c.copyWith(density: d))),
              _head(t, '帧率'),
              for (final (label, f) in const [('1 fps', 1), ('5 fps', 5), ('15 fps', 15), ('30 fps（看视频）', 30)])
                _Item(label, checked: !c.smart && c.fps == f, onTap: () => _choose(c.copyWith(fps: f))),
              _Item('记为这个 app 的默认', enabled: widget.onRememberStream != null, onTap: () => _then(widget.onRememberStream!)),
    ];
  }

  Widget _head(RappTokens t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Text(text, style: TextStyle(color: t.muted, letterSpacing: t.labelSpacing * t.textSize)),
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
        style: TextStyle(fontFamily: t.mono, fontFamilyFallback: t.monoFallback, color: t.muted));
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
  const _Item(this.label, {super.key, this.checked = false, this.enabled = true, this.onTap, this.trailing, this.indent = 0});
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
      constraints: BoxConstraints(minHeight: controlHeightOf(context)),
      padding: EdgeInsets.only(left: 12 + indent, right: 12),
      child: Row(
        children: [
          SizedBox(width: 18, child: checked ? Icon(Icons.check, size: 18, color: t.text) : null),
          const SizedBox(width: 8),
          Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: color))),
          ?trailing,
        ],
      ),
    );
    if (!active) {
      return Semantics(enabled: false, selected: checked, label: label, excludeSemantics: true, child: row);
    }
    // A trailing button sits beside the row's own tap target, not inside it.
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(RappTokens.of(context).r), child: row);
  }
}
