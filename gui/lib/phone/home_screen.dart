/// The phone home page, read-only: what waits for you, what is working, what finished (V1b Task 6, H1-H11).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'devices_page.dart';
import 'enter_when_open.dart';
import 'home_model.dart';
import 'phone_nav.dart';
import 'phone_voice.dart';
import 'reply_card.dart';
import 'reply_model.dart';
import 'sheet.dart';
import 'widgets.dart';

const _maxRows = 5;
const _maxWorking = 3;

/// The one home model of the phone: the home page and the fold (what waits) both read it.
HomeModel phoneHomeModel(MainState s, PhoneNav nav) {
  final sync = s.stateSync;
  final needs = s.needs;
  return buildHome(
    needs: needs,
    lists: s.hub?.termLists ?? const {},
    serviceSessions: sync?.sessionRows ?? const [],
    serviceRows: sync?.rows ?? const [],
    fromService: sync != null && s.needsFromService,
    offline: {for (final n in needs) if (n.kind == NeedKind.device) n.target},
    gotIt: nav.gotIt,
    deviceName: s.deviceName,
    sessionKeyOf: (d, t) => '$d/$t',
  );
}

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

  late final EnterWhenOpen _enter;

  MainState get _s => widget.state;
  PhoneNav get _nav => widget.nav;

  @override
  void initState() {
    super.initState();
    _enter = EnterWhenOpen(_s, _nav);
    _nav.addListener(_onNav);
  }

  @override
  void dispose() {
    _nav.removeListener(_onNav);
    _enter.dispose();
    super.dispose();
  }

  /// Leaving home drops a waiting enter and the expanded lists.
  void _onNav() {
    if (_nav.now != PhoneView.home) {
      _enter.cancel();
      _all = false;
      _allWorking = false;
    }
  }

  bool get _offline => _s.netDown || !_s.hubUsable;

  HomeModel _model() => phoneHomeModel(_s, _nav);

  void _goLook(HomeItem item) {
    setState(() => _nav.cameFrom = null);
    final need = item.need;
    final key = item.sessionKey;
    if (need == null) {
      if (key != null) _nav.enter(key);
      return;
    }
    // goToNeed returns nothing: it starts the open and returns, so a terminal that is not open yet lands later.
    _s.goToNeed(need);
    final cur = _s.currentKey;
    if (key == null) {
      if (cur != null) _nav.enter(cur);
    } else if (cur == key && _enter.isOpen(key)) {
      _nav.enter(key);
    } else if (_canOpen(need)) {
      _enter.arm(device: need.device ?? key.split('/').first, key: key);
    }
  }

  /// A need whose goToNeed starts an open: it needs the hub, and it is not a grey one.
  bool _canOpen(NeedItem n) => n.greyWord == null && (n.kind != NeedKind.terminal || _s.hubUsable);

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

  CardReply _replyOf(HomeItem card) {
    final p = card.id.split('\n');
    final row = p.length == 3 && p[0] == 'term'
        ? _s.hub?.termLists[p[1]]?.terms.where((r) => r.id == p[2]).firstOrNull
        : null;
    return replyOf(card, row: row, deviceReply: p.length == 3 && deviceCanReply(_s.probes, p[1]));
  }

  VoidCallback? _buttonOf(HomeItem item) {
    switch (item.button) {
      case HomeButton.goLook:
        final k = item.sessionKey;
        final need = item.need;
        // A terminal that is not open cannot be opened without the hub.
        if (_offline && need?.kind == NeedKind.terminal && (k == null || !_enter.isOpen(k))) return null;
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
    // Something to look at: cards and rows. Nothing but finished ones: the H7 lists instead.
    final h7 = m.items.every((i) => i.kind == HomeKind.done);
    final items = h7 ? const <HomeItem>[] : m.items;
    final empty = h7 && m.working.isEmpty && m.recentDone.isEmpty;
    final HomeItem? card = items.isEmpty ? null : (items.where((i) => i.id == _open).firstOrNull ?? items.first);
    final rows = [for (final i in items) if (i != card) i];
    final from = _nav.cameFrom;
    // A session that is gone has no row: its raw key is nothing to show or tap.
    final fromName = from == null ? null : _s.entryFor(from)?.title;
    final cap = _maxRows - (fromName != null ? 1 : 0);
    final shown = _all || rows.length <= cap + 1 ? rows : rows.take(cap).toList();
    final more = rows.length - shown.length;
    final second = [
      if (m.working.isNotEmpty) '${m.working.length} 个在干活',
      if (m.doneUnseen > 0) '做完 ${m.doneUnseen} 件',
    ].join(' · ');
    final noMotion = MediaQuery.disableAnimationsOf(context);
    // H10: eight taps in all. Header, second line, 刚才在 and the working rows come first; done rows take what is left.
    final workRows = _allWorking ? m.working.length : m.working.take(_maxWorking).length;
    final workMore = m.working.length - workRows > 0 ? 1 : 0;
    final doneRoom = 8 - 2 - (fromName != null ? 1 : 0) - workRows - workMore;
    final done = m.recentDone.take(doneRoom < 0 ? 0 : doneRoom).toList();
    final listOn = h7 && (m.working.isNotEmpty || m.recentDone.isNotEmpty);

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
              // One column, so the switcher keeps its place when the lines above it come and go.
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (second.isNotEmpty)
                    InkWell(
                      onTap: !listOn
                          ? null
                          : () {
                              final c = _workKey.currentContext;
                              if (c != null) {
                                Scrollable.ensureVisible(c, duration: noMotion ? Duration.zero : const Duration(milliseconds: 250));
                              }
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
                  AnimatedSwitcher(
                    key: const ValueKey('home-card'),
                    duration: noMotion ? Duration.zero : const Duration(milliseconds: 250),
                    // Only the card that leaves slides; the one that stays or arrives is just there.
                    transitionBuilder: (child, anim) => (child.key as ValueKey?)?.value == (card?.gotItKey ?? 'none')
                        ? child
                        : SlideTransition(
                            position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(anim),
                            child: child,
                          ),
                    child: card == null
                        ? const SizedBox.shrink(key: ValueKey('none'))
                        : Padding(
                            key: ValueKey(card.gotItKey),
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _focusCard(card),
                          ),
                  ),
                ],
              ),
              for (final i in shown)
                PhoneRow(
                  item: i,
                  onTap: () => setState(() => _open = i.id),
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
              if (listOn)
                Column(
                  key: _workKey,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (m.working.isNotEmpty) _working(context, m, style, t),
                    if (done.isNotEmpty) _done(done, style, t),
                  ],
                ),
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

  /// The focus card: with reply buttons when it has any, else today's single button.
  Widget _focusCard(HomeItem card) {
    final reply = _replyOf(card);
    if (reply.kind == ReplyKind.none) return PhoneCard(item: card, onOpen: null, onButton: _buttonOf(card));
    return PhoneCard(
      item: card,
      // The review points are cut short: the text opens the session for the full plan.
      onOpen: reply.kind == ReplyKind.review ? () => _goLook(card) : null,
      onButton: _buttonOf(card),
      actions: ReplyActions(
        item: card,
        reply: reply,
        replies: _nav.replies,
        voice: _s.voice == null ? null : (label, use) => _voiceFor(card, reply, label, use),
        onGotIt: reply.kind == ReplyKind.done ? _buttonOf(card) : null,
        onGoLook: () => _goLook(card),
      ),
    );
  }

  /// 「说一句」 / 「要改」: hold to talk; the words go through the reply path, no view (V4). 「编辑」 goes in.
  Widget _voiceFor(HomeItem item, CardReply reply, String label, ReplyVoiceUse use) {
    final t = reply.target;
    final seq = reply.seq;
    final keys = reply.planRevise;
    final revise = use == ReplyVoiceUse.revise;
    final replies = _nav.replies;
    return PhoneVoice(
      state: _s,
      key2: '${item.gotItKey}\n${use.name}',
      send: (text, voice) {
        if (t == null) return null;
        if (revise) {
          if (seq == null || keys == null) return null;
          unawaited(_revised(item, replies.revise(item.id, t, seq, keys, text)));
        } else {
          unawaited(replies.say(item.id, t, text));
        }
        return null;
      },
      edit: (text) {
        if (revise && t != null && seq != null && keys != null) {
          unawaited(_reviseEdit(item, t, seq, keys, text));
        } else {
          _editIn(item, text);
        }
      },
      builder: (context, hold) => phoneVoiceButton(hold, label),
    );
  }

  Future<void> _revised(HomeItem item, Future<void> sent) async {
    await sent;
    final eid = item.pointsEid;
    if (eid != null && _nav.replies.outcomeOf(item.id)?.failed != true) _nav.replies.markEid(eid);
  }

  Future<void> _reviseEdit(HomeItem item, ReplyTarget t, int seq, List<String> keys, String text) async {
    await _nav.replies.keys(item.id, t, seq, keys, doneWord: '已发出');
    if (_nav.replies.outcomeOf(item.id)?.failed == true) return;
    final eid = item.pointsEid;
    if (eid != null) _nav.replies.markEid(eid);
    if (mounted) _editIn(item, text);
  }

  void _editIn(HomeItem item, String text) {
    _nav.pendingDraft = text;
    _goLook(item);
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

  Widget _done(List<DoneRow> done, TextStyle style, RappTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('做完没看的', style, t),
          for (final d in done) _small(d.program, d.device, d.sessionKey, style, t, line: d.line),
        ],
      );
}

String _elapsed(int secs, int since) {
  if (since <= 0 || secs < 60) return '不到 1 分钟';
  if (secs < 3600) return '${secs ~/ 60} 分钟';
  return '${secs ~/ 3600} 小时';
}
