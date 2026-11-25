// The overview's 打开应用 menu: one device's apps, filterable, one tap opens or switches
// (spec 2026-11-25-rapp-overview-open-apps-design).
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../hub_client.dart';
import 'device_apps.dart';
import 'lamp.dart';
import 'lifecycle.dart' show disconnectWord;
import 'main_state.dart';
import 'session_model.dart';
import 'tokens.dart';

const _menuWidth = 290.0;
const _rowHeight = 32.0;

/// Gap between the link and the menu, and the least room kept to the window's edge.
const _gap = 6.0;
const _edge = 8.0;
const _minHeight = 200.0;

/// Opens the menu under [anchor] (above it when there is more room there), right edges lined up.
/// The device's running apps are read again on every open.
Future<void> showOpenAppsMenu(BuildContext anchor, MainState state, String id) {
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay = Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final rect = MatrixUtils.transformRect(box.getTransformTo(overlay), Offset.zero & box.size);
  state.probe(id);
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => CustomSingleChildLayout(
      delegate: _MenuLayout(rect),
      child: _OpenAppsMenu(state: state, id: id),
    ),
  );
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.anchor);
  final Rect anchor;

  double _below(Size s) => s.height - anchor.bottom - _gap - _edge;
  double _above() => anchor.top - _gap - _edge;
  bool _down(Size s) => _below(s) >= 320 || _below(s) >= _above();

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) {
    final room = _down(c.biggest) ? _below(c.biggest) : _above();
    // Never shorter than _minHeight (the filter, one row and the foot) while the window has it; then it may cover the link.
    final most = math.max(0.0, c.maxHeight - 2 * _edge);
    return BoxConstraints.tightFor(width: _menuWidth).copyWith(maxHeight: math.min(math.max(room, _minHeight), most));
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (anchor.right - child.width).clamp(_edge, (size.width - child.width - _edge).clamp(_edge, double.infinity));
    final y = _down(size) ? anchor.bottom + _gap : anchor.top - _gap - child.height;
    return Offset(x, y.clamp(_edge, (size.height - child.height - _edge).clamp(_edge, double.infinity)));
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.anchor != anchor;
}

class _OpenAppsMenu extends StatefulWidget {
  const _OpenAppsMenu({required this.state, required this.id});
  final MainState state;
  final String id;

  @override
  State<_OpenAppsMenu> createState() => _OpenAppsMenuState();
}

class _OpenAppsMenuState extends State<_OpenAppsMenu> {
  final _filter = TextEditingController();
  final _bundle = TextEditingController();
  final _scroll = ScrollController();

  /// The row Return opens, an index into the filtered rows.
  int _pick = 0;

  /// The filtered rows as last drawn, for the keys.
  List<HubApp> _rows = const [];

  MainState get state => widget.state;
  String get id => widget.id;

  @override
  void dispose() {
    _filter.dispose();
    _bundle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  void _open(String app, String name) {
    _close();
    state.openOrSwitch(id, app, name);
  }

  void _openPicked() {
    if (_pick < _rows.length) _open(_rows[_pick].app, _rows[_pick].name);
  }

  void _openBundle() {
    final b = _bundle.text.trim();
    if (b.isEmpty) return;
    _open(b, b);
  }

  void _move(int by) {
    if (_rows.isEmpty) return;
    setState(() => _pick = (_pick + by).clamp(0, _rows.length - 1));
    // Keep the pick in view: rows are fixed height, the group titles are close enough to ignore.
    if (_scroll.hasClients) {
      final top = _pick * _rowHeight;
      final view = _scroll.position.viewportDimension;
      if (top < _scroll.offset) _scroll.jumpTo(top);
      if (top + _rowHeight > _scroll.offset + view) _scroll.jumpTo(top + _rowHeight * 2 - view);
    }
  }

  SessionEntry? _session(String app) {
    for (final e in state.entries) {
      if (e.key == '$id/$app') return e;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    return Material(
      key: const Key('open-apps-menu'),
      type: MaterialType.transparency,
      child: Container(
        width: _menuWidth,
        decoration: t.floatBox(border: t.line).copyWith(
          boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 32, offset: Offset(0, 12))],
        ),
        padding: const EdgeInsets.all(6),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final p = state.probes[id];
            final apps = p?.apps;
            final groups = deviceAppGroups(apps, state.hub?.termLists[id]);
            final shown = filterAppGroups(groups, _filter.text);
            _rows = [for (final g in shown) ...g.apps];
            if (_pick >= _rows.length) _pick = _rows.isEmpty ? 0 : _rows.length - 1;
            final applications =
                apps?.capabilities?['graphical'] != false && apps?.capabilities?['applications'] != false;
            final String? empty = groups.isEmpty
                ? (apps == null
                    ? (p?.error != null && p?.lamp == Lamp.offline ? disconnectWord(p!.error) : '正在读取…')
                    : (apps.capabilities?['graphical'] == false ? '这台设备支持文本终端和端口分享，暂不提供应用画面' : '对方没有可共享的窗口'))
                : (shown.isEmpty ? '没有匹配的应用' : null);
            var i = 0;
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
                  const SingleActivator(LogicalKeyboardKey.escape): _close,
                },
                child: TextField(
                  key: const Key('open-apps-filter'),
                  controller: _filter,
                  // On iOS focusing would raise the on-screen keyboard over the menu.
                  autofocus: defaultTargetPlatform != TargetPlatform.iOS,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '输入筛选…',
                    prefixIcon: Icon(Icons.search, size: 16),
                    prefixIconConstraints: BoxConstraints(minWidth: 28),
                  ),
                  onChanged: (_) => setState(() => _pick = 0),
                  onSubmitted: (_) => _openPicked(),
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView(
                  controller: _scroll,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    if (empty != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                        child: Text(empty, style: small),
                      ),
                    for (final g in shown) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 3),
                        child: Text(g.title, style: small?.copyWith(letterSpacing: t.labelSpacing * t.textSize)),
                      ),
                      for (final a in g.apps) _row(context, a, i++),
                    ],
                  ],
                ),
              ),
              Divider(height: 12, color: t.line),
              if (applications)
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        key: const Key('open-apps-bundle'),
                        controller: _bundle,
                        style: small?.copyWith(color: t.text),
                        decoration: const InputDecoration(isDense: true, hintText: '其他 app 的包名（例：com.apple.TextEdit）'),
                        onSubmitted: (_) => _openBundle(),
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      key: const Key('open-apps-bundle-open'),
                      onPressed: state.hubUsable ? _openBundle : null,
                      child: const Text('打开'),
                    ),
                  ]),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('open-apps-details'),
                  onPressed: () {
                    _close();
                    state.showDevice(id);
                  },
                  child: Text('设备详情 ›', style: TextStyle(color: t.on)),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _row(BuildContext context, HubApp a, int index) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final session = _session(a.app);
    final picked = index == _pick;
    final word = session == null
        ? (picked ? '打开' : '')
        : (session.lamp == Lamp.disconnected ? '已断开' : '已打开');
    final fav = state.isFavorite(id, a.app);
    final favWord = fav ? '取消常用' : '设为常用';
    return SizedBox(
      key: Key('open-apps-row-${a.app}'),
      height: _rowHeight,
      child: Semantics(
        button: true,
        label: [a.name, session == null ? '没打开' : word, if (fav) '常用'].join('，'),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(t.r),
            onTap: state.hubUsable ? () => _open(a.app, a.name) : null,
            onHover: (on) {
              if (on && _pick != index) setState(() => _pick = index);
            },
            child: Ink(
              decoration: picked ? t.raiseBox(border: Colors.transparent) : null,
              padding: const EdgeInsets.only(left: 8),
              child: Row(children: [
                StatusLamp(session?.lamp ?? Lamp.notOpened),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text)),
                ),
                if (word.isNotEmpty) Text(word, style: small),
                IconButton(
                  key: Key('open-apps-star-${a.app}'),
                  tooltip: favWord,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: _rowHeight),
                  iconSize: 16,
                  icon: Icon(fav ? Icons.star : Icons.star_border, color: fav ? t.accent : t.muted),
                  onPressed: () => state.toggleFavorite(id, a.app, a.name),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
