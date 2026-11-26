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

/// Gap between the link and the menu, and the least room kept to the window's edge.
const _gap = 6.0;
const _edge = 8.0;

/// The filter, a row or two and the foot.
const _minHeight = 200.0;

bool get _touch => defaultTargetPlatform == TargetPlatform.iOS;

/// Rows are 32 with a pointer; on touch 44, so the star and the row are not easy to mix up.
double get _rowHeight => _touch ? 44 : 32;

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
      // The on-screen keyboard (iPad) takes the bottom of the window: the menu stays above it.
      delegate: _MenuLayout(rect, MediaQuery.viewInsetsOf(context).bottom),
      child: _OpenAppsMenu(state: state, id: id),
    ),
  );
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.anchor, this.inset);
  final Rect anchor;
  final double inset;

  double _height(Size s) => math.max(0, s.height - inset);
  double _below(Size s) => _height(s) - anchor.bottom - _gap - _edge;
  double _above() => anchor.top - _gap - _edge;
  bool _down(Size s) => _below(s) >= 320 || _below(s) >= _above();

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) {
    final room = _down(c.biggest) ? _below(c.biggest) : _above();
    // Never shorter than _minHeight while the window has it; then it may cover the link.
    final most = math.max(0.0, _height(c.biggest) - 2 * _edge);
    final width = math.min(_menuWidth, math.max(0.0, c.maxWidth - 2 * _edge));
    return BoxConstraints.tightFor(width: width).copyWith(maxHeight: math.min(math.max(room, _minHeight), most));
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (anchor.right - child.width).clamp(_edge, math.max(_edge, size.width - child.width - _edge));
    final y = _down(size) ? anchor.bottom + _gap : anchor.top - _gap - child.height;
    return Offset(x.toDouble(), y.clamp(_edge, math.max(_edge, _height(size) - child.height - _edge)).toDouble());
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.anchor != anchor || old.inset != inset;
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
  final _rowKeys = <String, GlobalKey>{};

  /// The app Return opens. Kept by id, so a list that grows under it (the probe answering) keeps the pick;
  /// null or gone = the first row.
  String? _pickApp;

  /// On touch nothing is picked until a hardware key moves the pick.
  bool _keyed = false;

  /// The filtered rows as last drawn, for the keys.
  List<HubApp> _rows = const [];

  MainState get state => widget.state;
  String get id => widget.id;

  int get _pick => math.max(0, _rows.indexWhere((a) => a.app == _pickApp));

  /// The hub can open things and the device was not just found offline.
  bool get _canOpen => state.hubUsable && state.probes[id]?.lamp != Lamp.offline;

  @override
  void dispose() {
    _filter.dispose();
    _bundle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  void _open(String app, String name) {
    if (!_canOpen) return;
    _close();
    state.openOrSwitch(id, app, name);
  }

  void _openPicked() {
    if (_rows.isNotEmpty) _open(_rows[_pick].app, _rows[_pick].name);
  }

  void _openBundle() {
    final b = _bundle.text.trim();
    if (b.isEmpty) return;
    _open(b, b);
  }

  void _move(int by) {
    if (_rows.isEmpty) return;
    final next = _keyed || !_touch ? (_pick + by).clamp(0, _rows.length - 1) : 0;
    setState(() {
      _keyed = true;
      _pickApp = _rows[next].app;
    });
    final key = _rowKeys[_rows[next].app];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = key?.currentContext;
      if (c == null || !c.mounted) return;
      Scrollable.ensureVisible(
        c,
        alignmentPolicy: by > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  SessionEntry? _session(String app) {
    for (final e in state.entries) {
      if (e.key == '$id/$app') return e;
    }
    return null;
  }

  /// The lines over the rows: why the device cannot be reached, what is still coming, why a group is missing.
  List<String> _notes(DeviceProbe? p, List<DeviceAppGroup> groups, List<DeviceAppGroup> shown) {
    final apps = p?.apps;
    final offline = p?.lamp == Lamp.offline && p?.error != null;
    final termError = state.hub?.termLists[id]?.error;
    return [
      if (offline) disconnectWord(p!.error),
      if (apps == null && !offline) '正在读取…',
      if (apps != null && apps.capabilities?['graphical'] == false) '这台设备支持文本终端和端口分享，暂不提供应用画面',
      if (apps != null && apps.capabilities?['graphical'] != false && apps.apps.isEmpty) '对方没有可共享的窗口',
      if (termError != null) '终端：$termError',
      if (groups.isNotEmpty && shown.isEmpty) '没有匹配的应用',
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    return Material(
      key: const Key('open-apps-menu'),
      type: MaterialType.transparency,
      child: Container(
        decoration: t
            .floatBox(border: t.line)
            .copyWith(
              boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 32, offset: Offset(0, 12))],
            ),
        padding: const EdgeInsets.all(6),
        // The keys work from either field, and on iPad with a hardware keyboard before any field has focus.
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
            const SingleActivator(LogicalKeyboardKey.escape): _close,
          },
          child: Focus(
            autofocus: _touch,
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) {
                final p = state.probes[id];
                final apps = p?.apps;
                final groups = deviceAppGroups(apps, state.hub?.termLists[id]);
                final shown = filterAppGroups(groups, _filter.text, shownAs: (a) => state.titleOf(id, a.app, a.name));
                _rows = [for (final g in shown) ...g.apps];
                final applications =
                    apps?.capabilities?['graphical'] != false && apps?.capabilities?['applications'] != false;
                final notes = _notes(p, groups, shown);
                var i = 0;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('open-apps-filter'),
                      controller: _filter,
                      // On iOS focusing would raise the on-screen keyboard over the menu.
                      autofocus: !_touch,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '输入筛选…',
                        prefixIcon: Icon(Icons.search, size: 16),
                        prefixIconConstraints: BoxConstraints(minWidth: 28),
                      ),
                      onChanged: (_) => setState(() => _pickApp = null),
                      onSubmitted: (_) => _openPicked(),
                    ),
                    const SizedBox(height: 4),
                    Flexible(
                      child: SingleChildScrollView(
                        controller: _scroll,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final n in notes)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                child: Text(n, style: small),
                              ),
                            for (final g in shown) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 6, 8, 3),
                                child: Text(
                                  g.title,
                                  style: small?.copyWith(letterSpacing: t.labelSpacing * t.textSize),
                                ),
                              ),
                              for (final a in g.apps) _row(context, a, i++),
                            ],
                          ],
                        ),
                      ),
                    ),
                    Divider(height: 12, color: t.line),
                    if (applications)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('open-apps-bundle'),
                                controller: _bundle,
                                style: small?.copyWith(color: t.text),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  hintText: '其他 app 的包名（例：com.apple.TextEdit）',
                                ),
                                onSubmitted: (_) => _openBundle(),
                              ),
                            ),
                            const SizedBox(width: 6),
                            TextButton(
                              key: const Key('open-apps-bundle-open'),
                              onPressed: _canOpen ? _openBundle : null,
                              child: const Text('打开'),
                            ),
                          ],
                        ),
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
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, HubApp a, int index) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final session = _session(a.app);
    final picked = index == _pick && (_keyed || !_touch);
    final word = switch (session?.lamp) {
      null => picked ? '打开' : '',
      Lamp.connecting => '连接中',
      Lamp.disconnected => '已断开',
      _ => '已打开',
    };
    final shown = state.titleOf(id, a.app, a.name);
    final fav = state.isFavorite(id, a.app);
    final favWord = fav ? '取消常用' : '设为常用';
    // Like the device panel: a row already connecting does not open again.
    final tappable = _canOpen && session?.lamp != Lamp.connecting;
    return SizedBox(
      key: _rowKeys.putIfAbsent(a.app, GlobalKey.new),
      height: _rowHeight,
      child: Semantics(
        button: true,
        enabled: tappable,
        label: [shown, if (shown != a.name) a.name, session == null ? '没打开' : word, if (fav) '常用'].join('，'),
        child: Material(
          key: Key('open-apps-row-${a.app}'),
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(t.r),
            onTap: tappable ? () => _open(a.app, a.name) : null,
            onHover: (on) {
              if (on && _pickApp != a.app) setState(() => _pickApp = a.app);
            },
            child: Ink(
              decoration: picked ? t.raiseBox(border: Colors.transparent) : null,
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  StatusLamp(session?.lamp ?? Lamp.notOpened),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            shown,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: tappable ? t.text : t.muted),
                          ),
                        ),
                        // A labelled app: its own name in small type after the label's title (spec §7.6).
                        if (shown != a.name) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (word.isNotEmpty) Text(word, style: small),
                  IconButton(
                    key: Key('open-apps-star-${a.app}'),
                    tooltip: favWord,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(minWidth: _rowHeight, minHeight: _rowHeight),
                    iconSize: 16,
                    icon: Icon(fav ? Icons.star : Icons.star_border, color: fav ? t.accent : t.muted),
                    onPressed: () => state.toggleFavorite(id, a.app, a.name),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
