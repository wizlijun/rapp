// 常用语条, the 快捷区 first row (phrases spec §2, §5; quick-row spec §5): the starred items, or every item by use
// count, then 「按键▾」「常用语▾」 pinned at its right. A tap sends ([sendPhrase], [sendStripCmd], [sendKeyAction]) and
// counts a use; a long press gives 放进输入框再改 / 编辑 / 打星 / 移到最前 / 删除. Like the keys, nothing here takes the
// focus.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/keys_page.dart';
import '../pages/phrases_page.dart';
import '../quick/key_actions.dart';
import '../quick/quick_row.dart';
import '../quick/quick_usage.dart';
import '../term/term_session_port.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'composer_plus.dart';
import 'phrase_send.dart';
import 'phrases.dart';
import 'remote_session.dart';
import 'session_port.dart';
import 'strip_cmds.dart';
import 'strip_tools.dart';

class PhraseStrip extends StatefulWidget {
  const PhraseStrip({super.key, required this.state, required this.session, required this.port});

  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  @override
  State<PhraseStrip> createState() => _PhraseStripState();
}

/// Which of the two menus a sheet lists.
enum _Kind { phrases, keys }

class _PhraseStripState extends State<PhraseStrip> {
  /// The ref (`p:` / `k:`) of the chip that just went, shown with ✓ for [phraseTickTime].
  String? _ticked;
  String? _hint;
  Timer? _tickTimer, _hintTimer;

  /// The row's order, worked out once per (session, stars, phrases `at`, keys `at`) (Ruling 9): counts going up while
  /// in use do not reshuffle it.
  List<String>? _order;
  Object? _orderSid;
  List<String> _orderStars = const [];
  int _orderPhrasesAt = -1, _orderKeysAt = -1;

  @override
  void didUpdateWidget(PhraseStrip old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) _order = null;
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  AgentTool? get _tool => widget.state.stripToolOf(widget.session);

  bool get _term => widget.port is TermSessionPort;

  /// The refs in row order (all of them; whether one may show here is the caller's business).
  List<String> _rowOrder() {
    final q = widget.state.quick;
    final pAt = q.atOf('phrases'), kAt = q.atOf('keys');
    if (_order == null ||
        _orderSid != widget.session.sid ||
        !listEquals(_orderStars, q.stars) ||
        _orderPhrasesAt != pAt ||
        _orderKeysAt != kAt) {
      _orderSid = widget.session.sid;
      _orderStars = List.of(q.stars);
      _orderPhrasesAt = pAt;
      _orderKeysAt = kAt;
      _order = quickRowOrder(
        phraseRefs: [for (final it in q.phrases) refOf(it)],
        keyRefs: [for (final a in q.keys) a.ref],
        stars: q.stars,
        totals: usageTotals([q.usage, ...q.others.values], DateTime.now()),
      );
    }
    return _order!;
  }

  /// Why [a] cannot go here: the tool has no such key, or a terminal cannot send the chord.
  String _keyHint(KeyAction a, AgentTool? tool) {
    if (tool != null && chordFor(a, tool) == null) return '${tool.name} 没有这个命令';
    return '这里发不了 ${a.chord.label}';
  }

  /// What a refused tap says ([o] not sent or put); null when there is nothing to say.
  String? _why(PhraseOutcome o, {AgentTool? tool, KeyAction? key}) {
    if (o == PhraseOutcome.missing && key != null) return _keyHint(key, tool);
    if (o == PhraseOutcome.missing && tool == null) return null;
    return stripHint(o, tool: tool);
  }

  /// One tap on [p].
  PhraseOutcome _tap(Phrase p, String ref) =>
      _done(sendPhrase(state: widget.state, session: widget.session, port: widget.port, p: p), ref);

  /// One tap on the command [c]: grey ones say what is missing.
  PhraseOutcome _tapCmd(StripCmd c, String ref) {
    final tool = _tool;
    if (tool == null) return PhraseOutcome.missing;
    if (actionFor(c, tool) == null) return _done(PhraseOutcome.missing, ref, tool: tool);
    final o = sendStripCmd(state: widget.state, session: widget.session, port: widget.port, c: c, tool: tool);
    return _done(o, ref, tool: tool);
  }

  /// One tap on the key action [a].
  PhraseOutcome _tapKey(KeyAction a) {
    final tool = _tool;
    final o = sendKeyAction(state: widget.state, session: widget.session, port: widget.port, a: a, tool: tool);
    return _done(o, a.ref, tool: tool, key: a);
  }

  PhraseOutcome _done(PhraseOutcome o, String ref, {AgentTool? tool, KeyAction? key}) {
    if (!mounted) return o;
    switch (o) {
      case PhraseOutcome.sent:
        widget.state.recordUse(ref);
        unawaited(HapticFeedback.lightImpact());
        _tickTimer?.cancel();
        setState(() => _ticked = ref);
        _tickTimer = Timer(phraseTickTime, () {
          if (mounted) setState(() => _ticked = null);
        });
      case PhraseOutcome.put:
        widget.state.recordUse(ref);
      case PhraseOutcome.offline || PhraseOutcome.busy || PhraseOutcome.missing:
        final h = _why(o, tool: tool, key: key);
        if (h != null) _say(h);
      case PhraseOutcome.tooSoon:
        break;
    }
    return o;
  }

  void _say(String hint) {
    _hintTimer?.cancel();
    setState(() => _hint = hint);
    _hintTimer = Timer(phraseHintTime, () {
      if (mounted) setState(() => _hint = null);
    });
  }

  RappMenuItem<String> _starItem(String ref) => RappMenuItem(
      value: 'star', key: const Key('phrase-menu-star'), label: widget.state.quick.stars.contains(ref) ? '取消星标' : '打星');

  /// The long-press menu of the [i]th item of the 常用语 doc.
  Future<void> _menu(int i, Offset at) async {
    final all = widget.state.quick.phrases;
    if (i >= all.length) return;
    final item = all[i];
    final ref = refOf(item);
    final pick = await showRappMenu<String>(context, position: menuAt(context, at), items: [
      if (item is Phrase) const RappMenuItem(value: 'put', key: Key('phrase-menu-put'), label: '放进输入框再改'),
      const RappMenuItem(value: 'edit', key: Key('phrase-menu-edit'), label: '编辑'),
      _starItem(ref),
      if (widget.state.quick.stars.contains(ref))
        const RappMenuItem(value: 'first', key: Key('phrase-menu-first'), label: '移到最前'),
      const RappMenuItem(value: 'delete', key: Key('phrase-menu-delete'), label: '删除'),
    ]);
    if (!mounted || pick == null) return;
    final l = List.of(widget.state.quick.phrases);
    final at0 = l.indexOf(item);
    if (at0 < 0) return; // changed meanwhile
    switch (pick) {
      case 'put':
        if (item is Phrase) putIntoComposer(widget.session, item.text);
      case 'edit':
        final StripItem? e =
            item is StripCmd ? await editStripCmd(context, c: item) : await editPhrase(context, p: item as Phrase);
        if (e == null) return;
        final now = List.of(widget.state.quick.phrases);
        final j = now.indexOf(item);
        if (j >= 0) widget.state.setStripItems(now..[j] = e);
      case 'star':
        widget.state.toggleStar(ref);
      case 'first':
        widget.state.starFirst(ref);
      case 'delete':
        widget.state.setStripItems(l..removeAt(at0));
    }
  }

  /// The long-press menu of the key action [a]: 编辑 / 打星 / 删除.
  Future<void> _keyMenu(KeyAction a, Offset at) async {
    final pick = await showRappMenu<String>(context, position: menuAt(context, at), items: [
      const RappMenuItem(value: 'edit', key: Key('keyact-menu-edit'), label: '编辑'),
      _starItem(a.ref),
      const RappMenuItem(value: 'delete', key: Key('keyact-menu-delete'), label: '删除'),
    ]);
    if (!mounted || pick == null) return;
    switch (pick) {
      case 'edit':
        final r = await editKeyAction(context, start: a);
        if (r != null && mounted) {
          widget.state.setKeyActions([for (final k in widget.state.quick.keys) if (k.id == a.id) r else k]);
        }
      case 'star':
        widget.state.toggleStar(a.ref);
      case 'delete':
        widget.state.setKeyActions([for (final k in widget.state.quick.keys) if (k.id != a.id) k]);
    }
  }

  /// 「按键▾」 or 「常用语▾」: every item of [kind] with its star, then 设置…. A tap uses the item and closes the sheet;
  /// a refused one says why on its row and the sheet stays; a star only stars.
  Future<void> _sheet(_Kind kind) {
    // The row last refused, and why; kept across the sheet's rebuilds.
    (String, String)? said;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RappTokens.of(context).bg,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => ListenableBuilder(
          listenable: widget.state,
          builder: (sheet, _) {
            final t = RappTokens.of(sheet);
            final q = widget.state.quick;
            final tool = _tool;

            void use(String ref, PhraseOutcome Function() go, {String? Function(PhraseOutcome)? why}) {
              final o = go();
              if (o == PhraseOutcome.sent || o == PhraseOutcome.put) {
                Navigator.of(sheet).pop();
                return;
              }
              final h = why != null ? why(o) : _why(o, tool: tool);
              setSheet(() => said = h == null ? null : (ref, h));
            }

            Widget row({
              required Key key,
              required Key starKey,
              required String ref,
              required String title,
              String? chord,
              bool put = false,
              bool grey = false,
              required VoidCallback onTap,
            }) {
              final starred = q.stars.contains(ref);
              final hint = said?.$1 == ref ? said!.$2 : null;
              final tile = ListTile(
                key: key,
                title: Text(title, style: TextStyle(color: t.text)),
                subtitle: hint == null
                    ? null
                    : Text(hint, key: const Key('menu-hint'), style: TextStyle(color: t.muted, fontSize: 13)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (put) Icon(Icons.keyboard_return, color: t.muted, size: 18),
                  if (chord != null) Text(chord, style: TextStyle(color: t.muted, fontSize: 13)),
                  IconButton(
                    key: starKey,
                    icon: Icon(starred ? Icons.star : Icons.star_border, color: starred ? t.accent : t.muted),
                    onPressed: () => widget.state.toggleStar(ref),
                  ),
                ]),
                onTap: onTap,
              );
              return grey ? Opacity(opacity: .4, child: tile) : tile;
            }

            final rows = switch (kind) {
              _Kind.phrases => [
                  for (final (i, it) in q.phrases.indexed)
                    if (it is StripCmd && tool != null)
                      row(
                        key: Key('menu-p-$i'),
                        starKey: Key('menu-star-p-$i'),
                        ref: refOf(it),
                        title: it.labelOf(),
                        grey: actionFor(it, tool) == null,
                        onTap: () => use(refOf(it), () => _tapCmd(it, refOf(it))),
                      )
                    else if (it is Phrase)
                      row(
                        key: Key('menu-p-$i'),
                        starKey: Key('menu-star-p-$i'),
                        ref: refOf(it),
                        title: it.text,
                        put: it.put,
                        onTap: () => use(refOf(it), () => _tap(it, refOf(it))),
                      ),
                ],
              _Kind.keys => [
                  for (final a in q.keys)
                    if (keyActionUsable(a, term: _term, tool: tool))
                      row(
                        key: Key('menu-k-${a.id}'),
                        starKey: Key('menu-star-k-${a.id}'),
                        ref: a.ref,
                        title: a.label,
                        chord: chordFor(a, tool)?.label,
                        onTap: () => use(a.ref, () => _tapKey(a), why: (o) => _why(o, tool: tool, key: a)),
                      )
                    else
                      row(
                        key: Key('menu-k-${a.id}'),
                        starKey: Key('menu-star-k-${a.id}'),
                        ref: a.ref,
                        title: a.label,
                        chord: (chordFor(a, tool) ?? a.chord).label,
                        grey: true,
                        onTap: () => setSheet(() => said = (a.ref, _keyHint(a, tool))),
                      ),
                ],
            };
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * .6),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    child: Text(kind == _Kind.keys ? '按键' : '常用语',
                        style: TextStyle(color: t.text, fontSize: t.textSize + 2)),
                  ),
                  Flexible(
                    child: ListView(shrinkWrap: true, children: [
                      ...rows,
                      ListTile(
                        key: const Key('menu-settings'),
                        title: Text('设置…', style: TextStyle(color: t.text)),
                        onTap: () {
                          Navigator.of(sheet).pop();
                          if (kind == _Kind.keys) {
                            openKeysPage(context, widget.state);
                          } else {
                            openPhrasesPage(context, widget.state);
                          }
                        },
                      ),
                    ]),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.state, widget.session.composer]),
      builder: (context, _) {
        final blocked = phraseBlock(widget.state, widget.session) != null;
        final hint = _hint;
        Widget chip(Key key, String label, {required VoidCallback onTap, GestureLongPressStartCallback? onLong,
            bool ticked = false, bool put = false, bool cmd = false, bool grey = false}) {
          final color = ticked ? t.on : (cmd ? t.accent : t.line);
          Widget c = Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              key: key,
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              onLongPressStart: onLong,
              child: Container(
                height: phraseStripChip,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: ticked ? Color.alphaBlend(t.on.withValues(alpha: .18), t.raise.first) : t.raise.first,
                  borderRadius: BorderRadius.circular(phraseStripChip / 2),
                  border: Border.all(color: color, width: ticked ? 2 : 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (ticked) ...[Icon(Icons.check, size: 14, color: t.on), const SizedBox(width: 3)],
                  Text(label, maxLines: 1, style: TextStyle(fontSize: 13, color: t.text)),
                  if (put) ...[const SizedBox(width: 3), Icon(Icons.keyboard_return, size: 12, color: t.muted)],
                ]),
              ),
            ),
          );
          if (grey) c = Opacity(opacity: .4, child: c);
          return cmd ? Semantics(label: '命令：$label', button: true, excludeSemantics: true, child: c) : c;
        }

        final tool = _tool;
        final q = widget.state.quick;
        // Refs to items: a phrase or command by its index in the doc (the chip's key), a key action by itself.
        final phraseAt = <String, int>{};
        for (final (i, it) in q.phrases.indexed) {
          phraseAt.putIfAbsent(refOf(it), () => i);
        }
        final keyOf = <String, KeyAction>{for (final a in q.keys.reversed) a.ref: a};
        final chips = <Widget>[];
        for (final ref in _rowOrder()) {
          final i = phraseAt[ref];
          final a = keyOf[ref];
          if (i != null) {
            final it = q.phrases[i];
            if (it case final StripCmd c) {
              if (tool == null) continue;
              chips.add(chip(Key('phrase-$i'), c.labelOf(),
                  ticked: _ticked == ref,
                  cmd: true,
                  grey: actionFor(c, tool) == null,
                  onTap: () => _tapCmd(c, ref),
                  onLong: (d) => _menu(i, d.globalPosition)));
            } else if (it case final Phrase p) {
              chips.add(chip(Key('phrase-$i'), p.text,
                  ticked: _ticked == ref,
                  put: p.put,
                  onTap: () => _tap(p, ref),
                  onLong: (d) => _menu(i, d.globalPosition)));
            }
          } else if (a != null && keyActionUsable(a, term: _term, tool: tool)) {
            chips.add(chip(Key('keyact-${a.id}'), a.label,
                ticked: _ticked == ref, onTap: () => _tapKey(a), onLong: (d) => _keyMenu(a, d.globalPosition)));
          }
        }
        return SizedBox(
          height: phraseStripChip,
          child: Row(children: [
            Expanded(
              child: hint != null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Text(hint, key: const Key('phrase-hint'), style: TextStyle(color: t.muted, fontSize: 13)),
                    )
                  : Opacity(
                      opacity: blocked ? .4 : 1,
                      child: ListView(
                        key: const Key('phrase-strip-list'),
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.zero,
                        children: chips,
                      ),
                    ),
            ),
            chip(const Key('quick-menu-keys'), '按键▾', onTap: () => _sheet(_Kind.keys)),
            chip(const Key('quick-menu-phrases'), '常用语▾', onTap: () => _sheet(_Kind.phrases)),
          ]),
        );
      },
    );
  }
}
