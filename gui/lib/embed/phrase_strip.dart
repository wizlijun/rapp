// 常用语条 (iOS): the row of phrases on top of the key bar, 「全部 ›」 pinned at its right (phrases spec §2, §5).
// A tap sends ([sendPhrase]); a long press gives 放进输入框再改 / 编辑 / 移到最前 / 删除. Like the keys, nothing here
// takes the focus.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/phrases_page.dart';
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

class _PhraseStripState extends State<PhraseStrip> {
  /// The chip that just went, shown with ✓ for [phraseTickTime].
  int? _ticked;
  String? _hint;
  Timer? _tickTimer, _hintTimer;

  @override
  void dispose() {
    _tickTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  AgentTool? get _tool => widget.state.stripToolOf(widget.session);

  /// What the strip shows now: each item with its index in the whole `prefs.phrases` (the key and the edit index).
  /// Commands only with a tool in front.
  List<(int, StripItem)> get _items {
    final tool = _tool;
    return [
      for (final (i, it) in widget.state.prefs.phrases.indexed)
        if (it is Phrase || tool != null) (i, it),
    ];
  }

  /// One tap on [p] (the [i]th of the whole list; null from the 全部 sheet).
  PhraseOutcome _tap(Phrase p, int? i) =>
      _done(sendPhrase(state: widget.state, session: widget.session, port: widget.port, p: p), i);

  /// One tap on the command [c]: grey ones say what is missing.
  PhraseOutcome _tapCmd(StripCmd c, int? i) {
    final tool = _tool;
    if (tool == null) return PhraseOutcome.missing;
    if (actionFor(c, tool) == null) return _done(PhraseOutcome.missing, i, tool: tool);
    final o = sendStripCmd(state: widget.state, session: widget.session, port: widget.port, c: c, tool: tool);
    return _done(o, i, tool: tool);
  }

  PhraseOutcome _done(PhraseOutcome o, int? i, {AgentTool? tool}) {
    if (!mounted) return o;
    switch (o) {
      case PhraseOutcome.sent:
        unawaited(HapticFeedback.lightImpact());
        _tickTimer?.cancel();
        setState(() => _ticked = i);
        _tickTimer = Timer(phraseTickTime, () {
          if (mounted) setState(() => _ticked = null);
        });
      case PhraseOutcome.offline || PhraseOutcome.busy || PhraseOutcome.missing:
        final h = stripHint(o, tool: tool);
        if (h != null) _say(h);
      case PhraseOutcome.put || PhraseOutcome.tooSoon:
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

  /// The long-press menu of the [i]th item of the whole list.
  Future<void> _menu(int i, Offset at) async {
    final all = widget.state.prefs.phrases;
    if (i >= all.length) return;
    final item = all[i];
    final pick = await showRappMenu<String>(context, position: menuAt(context, at), items: [
      if (item is Phrase) const RappMenuItem(value: 'put', key: Key('phrase-menu-put'), label: '放进输入框再改'),
      const RappMenuItem(value: 'edit', key: Key('phrase-menu-edit'), label: '编辑'),
      const RappMenuItem(value: 'first', key: Key('phrase-menu-first'), label: '移到最前'),
      const RappMenuItem(value: 'delete', key: Key('phrase-menu-delete'), label: '删除'),
    ]);
    if (!mounted || pick == null) return;
    final l = List.of(widget.state.prefs.phrases);
    final at0 = l.indexOf(item);
    if (at0 < 0) return; // changed meanwhile
    switch (pick) {
      case 'put':
        if (item is Phrase) putIntoComposer(widget.session, item.text);
      case 'edit':
        if (item is! Phrase) return; // TODO(Task 5): editStripCmd for a command
        final e = await editPhrase(context, p: item);
        if (e == null) return;
        final now = List.of(widget.state.prefs.phrases);
        final j = now.indexOf(item);
        if (j >= 0) widget.state.setStripItems(now..[j] = e);
      case 'first':
        widget.state.setStripItems([item, ...l..removeAt(at0)]);
      case 'delete':
        widget.state.setStripItems(l..removeAt(at0));
    }
  }

  Future<void> _all() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: RappTokens.of(context).bg,
        builder: (sheet) {
          final t = RappTokens.of(sheet);
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * .6),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(children: [
                    Expanded(child: Text('常用语', style: TextStyle(color: t.text, fontSize: t.textSize + 2))),
                    RappButton.quiet(
                      key: const Key('phrases-all-edit'),
                      label: '编辑',
                      onPressed: () {
                        Navigator.of(sheet).pop();
                        openPhrasesPage(context, widget.state);
                      },
                    ),
                  ]),
                ),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final (i, it) in _items)
                      if (it case final StripCmd c)
                        ListTile(
                          key: Key('phrases-all-$i'),
                          title: Text(c.labelOf(), style: TextStyle(color: t.text)),
                          onTap: () {
                            final o = _tapCmd(c, i);
                            if (o == PhraseOutcome.sent) Navigator.of(sheet).pop();
                          },
                        )
                      else if (it case final Phrase p)
                        ListTile(
                          key: Key('phrases-all-$i'),
                          title: Text(p.text, style: TextStyle(color: t.text)),
                          trailing: p.put ? Icon(Icons.keyboard_return, color: t.muted, size: 18) : null,
                          onTap: () {
                            final o = _tap(p, i);
                            if (o == PhraseOutcome.sent || o == PhraseOutcome.put) Navigator.of(sheet).pop();
                          },
                        ),
                  ]),
                ),
              ]),
            ),
          );
        },
      );

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
        final list = _items;
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
                        children: [
                          for (final (i, it) in list)
                            if (it case final StripCmd c)
                              chip(Key('phrase-$i'), c.labelOf(),
                                  ticked: _ticked == i,
                                  cmd: true,
                                  grey: tool != null && actionFor(c, tool) == null,
                                  onTap: () => _tapCmd(c, i),
                                  onLong: (d) => _menu(i, d.globalPosition))
                            else if (it case final Phrase p)
                              chip(Key('phrase-$i'), p.text,
                                  ticked: _ticked == i,
                                  put: p.put,
                                  onTap: () => _tap(p, i),
                                  onLong: (d) => _menu(i, d.globalPosition)),
                        ],
                      ),
                    ),
            ),
            chip(const Key('phrases-all'), '全部 ›', onTap: _all),
          ]),
        );
      },
    );
  }
}
