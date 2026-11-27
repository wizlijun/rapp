/// The phone home page, read-only: what waits for you, what is working, what finished (V1b Task 6, H1-H11).
library;

import 'package:flutter/material.dart';

import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'devices_page.dart';
import 'home_model.dart';
import 'phone_nav.dart';
import 'sheet.dart';
import 'widgets.dart';

const _maxRows = 5;
const _maxWorking = 3;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state, required this.nav});
  final MainState state;
  final PhoneNav nav;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The item the user opened as the card (H6); null = the first one.
  String? _open;
  bool _all = false;
  bool _allWorking = false;
  final _workKey = GlobalKey();

  /// A 进去看 whose terminal is still opening: go in once it is the current one.
  String? _pending;

  MainState get _s => widget.state;
  PhoneNav get _nav => widget.nav;

  @override
  void initState() {
    super.initState();
    _s.addListener(_onState);
  }

  @override
  void dispose() {
    _s.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final p = _pending;
    if (p != null && _s.currentKey == p) {
      _pending = null;
      _nav.enter(p);
    }
  }

  bool get _offline => _s.netDown || !_s.hubUsable;

  HomeModel _model() {
    final lists = _s.hub?.termLists ?? const {};
    final sync = _s.stateSync;
    final needs = _s.needs;
    return buildHome(
      needs: needs,
      lists: lists,
      serviceSessions: sync?.sessionRows ?? const [],
      serviceRows: sync?.rows ?? const [],
      fromService: sync != null && _s.needsFromService,
      offline: {for (final n in needs) if (n.kind == NeedKind.device) n.target},
      gotIt: _nav.gotIt,
      deviceName: _s.deviceName,
      sessionKeyOf: (d, t) => '$d/$t',
    );
  }

  Future<void> _goLook(HomeItem item) async {
    setState(() => _nav.cameFrom = null);
    final need = item.need;
    final key = item.sessionKey;
    if (need == null) {
      if (key != null) _nav.enter(key);
      return;
    }
    // goToNeed returns nothing (it starts the open and returns); a stopped or unopened terminal lands later.
    _s.goToNeed(need);
    final cur = _s.currentKey;
    if (cur != null && (key == null || cur == key)) {
      _nav.enter(cur);
    } else if (key != null) {
      _pending = key;
    }
  }

  void _gotIt(HomeItem item) {
    final sync = _s.stateSync;
    setState(() {
      _nav.cameFrom = null;
      _nav.gotIt.add(item.gotItKey);
    });
    if (item.kind == HomeKind.resource && item.need != null) {
      _s.snoozeNeed(item.need!);
    }
    final eid = item.eid;
    if (eid != null) sync?.markHandled(eid);
    if (item.kind == HomeKind.done && _viaService(item)) {
      final p = item.id.split('\n');
      sync?.markSeen(p[1], p[2]);
    }
  }

  /// A done terminal of a device this machine has no terminal list for: only the service can clear it.
  bool _viaService(HomeItem i) {
    final p = i.id.split('\n');
    return p.length == 3 && p[0] == 'term' && _s.stateSync != null && !(_s.hub?.termLists.containsKey(p[1]) ?? false);
  }

  VoidCallback? _buttonOf(HomeItem item) {
    switch (item.button) {
      case HomeButton.goLook:
        return () => _goLook(item);
      case HomeButton.reconnect:
        if (_offline || item.need == null) return null;
        return () {
          setState(() => _nav.cameFrom = null);
          _s.reconnect(item.need!.target);
        };
      case HomeButton.gotIt:
        if (_offline && (item.eid != null || _viaService(item))) return null;
        return () => _gotIt(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_s, _nav]),
      builder: (context, _) => PhonePage(offline: _offline, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium!;
    final big = style.copyWith(fontSize: (style.fontSize ?? 14) * 2, fontWeight: FontWeight.w700, color: t.text);
    final m = _model();
    // With nothing waiting, the finished ones are listed under 做完没看的 (H7), not as cards.
    final items = m.waiting == 0 ? [for (final i in m.items) if (i.kind != HomeKind.done) i] : m.items;
    final empty = items.isEmpty && m.working.isEmpty && m.recentDone.isEmpty;
    final HomeItem? card = items.isEmpty ? null : (items.where((i) => i.id == _open).firstOrNull ?? items.first);
    final rows = [for (final i in items) if (i != card) i];
    final shown = _all ? rows : rows.take(_maxRows).toList();
    final more = rows.length - shown.length;
    final second = [
      if (m.working.isNotEmpty) '${m.working.length} 个在干活',
      if (m.doneUnseen > 0) '做完 ${m.doneUnseen} 件',
    ].join(' · ');
    final from = _nav.cameFrom;
    final fromName = from == null ? null : (_s.entryFor(from)?.title ?? from);
    final noMotion = MediaQuery.disableAnimationsOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => showPhoneSheet(context, _nav),
          child: Container(
            height: phoneTap,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('rapp ▾', style: style.copyWith(color: t.text, fontWeight: FontWeight.w600)),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: items.isEmpty
                    ? Text('没有等你的。', style: big)
                    : Text.rich(TextSpan(style: big, children: [
                        TextSpan(text: '${items.length}', style: TextStyle(color: t.accent)),
                        const TextSpan(text: ' 件等你'),
                      ])),
              ),
              if (second.isNotEmpty)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    final c = _workKey.currentContext;
                    if (c != null) Scrollable.ensureVisible(c, duration: noMotion ? Duration.zero : const Duration(milliseconds: 250));
                  },
                  child: Container(
                    constraints: const BoxConstraints(minHeight: phoneTap),
                    alignment: Alignment.centerLeft,
                    child: Text(second, style: style.copyWith(color: t.muted)),
                  ),
                ),
              if (fromName != null)
                InkWell(
                  onTap: () => _nav.enter(from!),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: phoneTap),
                    alignment: Alignment.centerLeft,
                    child: Text('刚才在：$fromName', style: style.copyWith(color: t.text)),
                  ),
                ),
              if (card != null)
                AnimatedSwitcher(
                  duration: noMotion ? Duration.zero : const Duration(milliseconds: 250),
                  transitionBuilder: (child, anim) => SlideTransition(
                    position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(anim),
                    child: child,
                  ),
                  child: Padding(
                    key: ValueKey(card.gotItKey),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: PhoneCard(
                      item: card,
                      onOpen: card.sessionKey == null ? null : () => _goLook(card),
                      onButton: _buttonOf(card),
                    ),
                  ),
                ),
              for (final i in shown)
                PhoneRow(
                  item: i,
                  onTap: () => setState(() {
                    _open = i.id;
                    _nav.cameFrom = null;
                  }),
                ),
              if (more > 0)
                InkWell(
                  onTap: () => setState(() => _all = true),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: phoneTap),
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('还有 $more 件', style: style.copyWith(color: t.muted)),
                  ),
                ),
              if (m.waiting == 0 && m.working.isNotEmpty) _working(context, m, style, t),
              if (m.waiting == 0 && m.recentDone.isNotEmpty) _done(m, style, t),
              if (empty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 8),
                  child: Text('我的设备', style: style.copyWith(color: t.muted)),
                ),
                SizedBox(height: 480, child: DeviceList(state: _s, nav: _nav)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _heading(String s, TextStyle style, RappTokens t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(s, style: style.copyWith(color: t.muted)),
      );

  Widget _small(String name, String device, String? key, TextStyle style, RappTokens t, {String? line, Widget? tail}) {
    return InkWell(
      onTap: key == null ? null : () => _nav.enter(key),
      child: Container(
        constraints: const BoxConstraints(minHeight: phoneTap),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text([name, device].where((x) => x.isNotEmpty).join(' · '), style: style.copyWith(color: t.text)),
            if (line != null && line.isNotEmpty) Text(line, style: style.copyWith(color: t.muted)),
            ?tail,
          ],
        ),
      ),
    );
  }

  Widget _working(BuildContext context, HomeModel m, TextStyle style, RappTokens t) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final list = _allWorking ? m.working : m.working.take(_maxWorking).toList();
    final rest = m.working.length - list.length;
    return Column(
      key: _workKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('在干活的', style, t),
        for (final w in list)
          _small(
            w.program,
            w.device,
            w.sessionKey,
            style,
            t,
            line: '干了 ${_elapsed(nowSec - w.since, w.since)}${w.progress == null ? '' : ' · ${w.progress!.round()}%'}',
            tail: w.progress == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: LinearProgressIndicator(
                      value: w.progress! / 100,
                      minHeight: 2,
                      color: t.on,
                      backgroundColor: t.line,
                    ),
                  ),
          ),
        if (rest > 0)
          InkWell(
            onTap: () => setState(() => _allWorking = true),
            child: Container(
              constraints: const BoxConstraints(minHeight: phoneTap),
              alignment: Alignment.centerLeft,
              child: Text('其余 $rest 个', style: style.copyWith(color: t.muted)),
            ),
          ),
      ],
    );
  }

  Widget _done(HomeModel m, TextStyle style, RappTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('做完没看的', style, t),
          for (final d in m.recentDone) _small(d.program, d.device, d.sessionKey, style, t, line: d.line),
        ],
      );
}

String _elapsed(int secs, int since) {
  if (since <= 0 || secs < 60) return '不到 1 分钟';
  if (secs < 3600) return '${secs ~/ 60} 分钟';
  return '${secs ~/ 3600} 小时';
}
